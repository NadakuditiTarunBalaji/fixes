function report = configureSubsystemSignals(options)
%CONFIGURESUBSYSTEMSIGNALS Configure selected Subsystem input/output signals.
%
% Properly resolves and displays propagated signal names (<signal_name>)
% inside Inports and outside Outports.

    createMissingSignalObjects = true;
    updateModelAfterChanges = true;
    saveChangesAfterProcessing = true;

    if nargin < 1 || isempty(options), options = struct(); end
    if ~isfield(options, 'ProcessInports'), options.ProcessInports = true; end
    if ~isfield(options, 'ProcessOutports'), options.ProcessOutports = true; end
    if ~isfield(options, 'ShowPropagation'), options.ShowPropagation = true; end
    if ~isfield(options, 'MustResolve'), options.MustResolve = true; end

    modelName = bdroot;
    if isempty(modelName) || strcmp(modelName, '0') || ~bdIsLoaded(modelName)
        error('configureSubsystemSignals:NoOpenModel', 'Open a Simulink model first.');
    end

    selectedBlock = gcb;
    if isempty(selectedBlock) || strcmp(selectedBlock, modelName)
        error('configureSubsystemSignals:NoSelectedBlock', 'Select a Subsystem block first.');
    end

    blockType = get_param(selectedBlock, 'BlockType');
    if ~strcmpi(blockType, 'SubSystem')
        error('configureSubsystemSignals:NotSubsystem', 'Selected block is not a Subsystem.');
    end

    fprintf('\n==================================================\n');
    fprintf('Configuring Subsystem: %s\n', selectedBlock);
    fprintf('==================================================\n');

    if options.ProcessInports
        inportReport = processSubsystemInports(modelName, selectedBlock, ...
            createMissingSignalObjects, options.MustResolve, options.ShowPropagation);
    else
        inportReport = createEmptyResultTable();
    end

    if options.ProcessOutports
        outportReport = processSubsystemOutports(modelName, selectedBlock, ...
            createMissingSignalObjects, options.MustResolve, options.ShowPropagation);
    else
        outportReport = createEmptyResultTable();
    end

    report = [inportReport; outportReport];

    if saveChangesAfterProcessing
        persistSignalObjectChanges(modelName);
    end

    % CRITICAL: Update diagram forces Simulink to resolve <> into <signal_name>
    if updateModelAfterChanges
        try
            set_param(modelName, 'SimulationCommand', 'update');
        catch updateErr
            fprintf(2, 'Note: Update diagram reported: %s\nPress Ctrl+D in the model to refresh labels.\n', updateErr.message);
        end
    end

    if saveChangesAfterProcessing
        saveModelIfRequired(modelName);
    end
end

function report = processSubsystemInports(modelName, selectedBlock, createMissingSignalObjects, mustResolve, showPropagation)
    internalInports = find_system(selectedBlock, 'SearchDepth', 1, ...
        'FollowLinks', 'on', 'LookUnderMasks', 'all', 'BlockType', 'Inport');

    if isempty(internalInports)
        report = createEmptyResultTable();
        return;
    end

    internalPortNumbers = cellfun(@(block) getNumericPortNumber(block), internalInports);
    [internalPortNumbers, sortIndex] = sort(internalPortNumbers);
    internalInports = internalInports(sortIndex);

    subsystemPortHandles = get_param(selectedBlock, 'PortHandles');
    externalInports = subsystemPortHandles.Inport(:);
    externalCount = numel(externalInports);

    resultPort = [];
    resultDirection = {};
    resultSignal = {};
    resultStatus = {};
    resultPropagation = {};
    resultDetails = {};

    for index = 1:numel(internalInports)
        internalInport = internalInports{index};
        portNumber = internalPortNumbers(index);
        signalName = strtrim(get_param(internalInport, 'Name'));
        status = 'Failed';
        propagationStatus = 'Not attempted';
        detail = '';

        try
            if isnan(portNumber) || portNumber < 1 || portNumber > externalCount
                status = 'Skipped';
                detail = sprintf('No matching external input port for Inport %g.', portNumber);
                appendResult(); continue;
            end

            [isValid, validationMessage] = validateSignalName(signalName, 'Inport');
            if ~isValid
                status = 'Failed'; detail = validationMessage;
                appendResult(); continue;
            end

            externalPortHandle = externalInports(portNumber);
            externalLineHandle = get_param(externalPortHandle, 'Line');
            if isempty(externalLineHandle) || any(externalLineHandle == -1)
                status = 'Skipped'; detail = 'External port is unconnected.';
                appendResult(); continue;
            end

            sourcePortHandle = get_param(externalLineHandle, 'SrcPortHandle');
            if isempty(sourcePortHandle) || any(sourcePortHandle == -1)
                status = 'Skipped'; detail = 'Could not resolve external source port.';
                appendResult(); continue;
            end

            skipResolve = false;
            if createMissingSignalObjects
                [objectLocation, skipResolve] = ensureSignalObject(modelName, signalName);
            else
                objectLocation = 'Creation disabled';
            end

            % 1. Name the upstream source port
            configureSourceSignal(sourcePortHandle(1), signalName, mustResolve && ~skipResolve);

            % 2. Name the external line feeding the subsystem so signal name propagates inward
            try
                if externalLineHandle > 0
                    set_param(externalLineHandle, 'Name', signalName);
                end
            catch
            end

            % 3. Enable propagation on the internal line leaving the inport
            if showPropagation
                propagationStatus = enablePropagationAfterInternalInport(internalInport);
            else
                propagationStatus = 'Propagation off';
            end

            if skipResolve
                status = 'Skipped';
                detail = sprintf('Kept parameter (%s). Resolve skipped to prevent Value error.', objectLocation);
            else
                status = 'Configured';
                detail = sprintf('Location: %s. %s', objectLocation, propagationStatus);
            end
        catch portException
            status = 'Failed'; detail = portException.message;
        end
        appendResult();
    end

    report = table(resultPort(:), string(resultDirection(:)), string(resultSignal(:)), ...
        string(resultStatus(:)), string(resultPropagation(:)), string(resultDetails(:)), ...
        'VariableNames', {'Port', 'Direction', 'Signal', 'Status', 'Propagation', 'Details'});

    function appendResult()
        resultPort(end + 1, 1) = portNumber;
        resultDirection{end + 1, 1} = 'Inport';
        resultSignal{end + 1, 1} = signalName;
        resultStatus{end + 1, 1} = status;
        resultPropagation{end + 1, 1} = propagationStatus;
        resultDetails{end + 1, 1} = detail;
    end
end

function report = processSubsystemOutports(modelName, selectedBlock, createMissingSignalObjects, mustResolve, showPropagation)
    internalOutports = find_system(selectedBlock, 'SearchDepth', 1, ...
        'FollowLinks', 'on', 'LookUnderMasks', 'all', 'BlockType', 'Outport');

    if isempty(internalOutports)
        report = createEmptyResultTable();
        return;
    end

    internalPortNumbers = cellfun(@(block) getNumericPortNumber(block), internalOutports);
    [internalPortNumbers, sortIndex] = sort(internalPortNumbers);
    internalOutports = internalOutports(sortIndex);

    subsystemPortHandles = get_param(selectedBlock, 'PortHandles');
    externalOutports = subsystemPortHandles.Outport(:);
    externalCount = numel(externalOutports);

    resultPort = [];
    resultDirection = {};
    resultSignal = {};
    resultStatus = {};
    resultPropagation = {};
    resultDetails = {};

    for index = 1:numel(internalOutports)
        internalOutport = internalOutports{index};
        portNumber = internalPortNumbers(index);
        signalName = strtrim(get_param(internalOutport, 'Name'));
        status = 'Failed';
        propagationStatus = 'Not attempted';
        detail = '';

        try
            if isnan(portNumber) || portNumber < 1 || portNumber > externalCount
                status = 'Skipped'; detail = 'Port number out of range.';
                appendResult(); continue;
            end

            [isValid, validationMessage] = validateSignalName(signalName, 'Outport');
            if ~isValid
                status = 'Failed'; detail = validationMessage;
                appendResult(); continue;
            end

            outportPortHandles = get_param(internalOutport, 'PortHandles');
            internalLineHandle = get_param(outportPortHandles.Inport(1), 'Line');
            if isempty(internalLineHandle) || any(internalLineHandle == -1)
                status = 'Skipped'; detail = 'Internal Outport is unconnected.';
                appendResult(); continue;
            end

            sourcePortHandle = get_param(internalLineHandle, 'SrcPortHandle');
            if isempty(sourcePortHandle) || any(sourcePortHandle == -1)
                status = 'Skipped'; detail = 'Could not resolve internal source.';
                appendResult(); continue;
            end

            skipResolve = false;
            if createMissingSignalObjects
                [objectLocation, skipResolve] = ensureSignalObject(modelName, signalName);
            else
                objectLocation = 'Creation disabled';
            end

            % 1. Name the internal source port
            configureSourceSignal(sourcePortHandle(1), signalName, mustResolve && ~skipResolve);

            % 2. Name the internal line entering the outport
            try
                if internalLineHandle > 0
                    set_param(internalLineHandle, 'Name', signalName);
                end
            catch
            end

            % 3. Enable propagation on the external line leaving the subsystem outport
            if showPropagation
                propagationStatus = enablePropagationAfterSubsystemOutport(externalOutports(portNumber));
            else
                propagationStatus = 'Propagation off';
            end

            if skipResolve
                status = 'Skipped';
                detail = sprintf('Kept parameter (%s). Resolve skipped to prevent Value error.', objectLocation);
            else
                status = 'Configured';
                detail = sprintf('Location: %s. %s', objectLocation, propagationStatus);
            end
        catch portException
            status = 'Failed'; detail = portException.message;
        end
        appendResult();
    end

    report = table(resultPort(:), string(resultDirection(:)), string(resultSignal(:)), ...
        string(resultStatus(:)), string(resultPropagation(:)), string(resultDetails(:)), ...
        'VariableNames', {'Port', 'Direction', 'Signal', 'Status', 'Propagation', 'Details'});

    function appendResult()
        resultPort(end + 1, 1) = portNumber;
        resultDirection{end + 1, 1} = 'Outport';
        resultSignal{end + 1, 1} = signalName;
        resultStatus{end + 1, 1} = status;
        resultPropagation{end + 1, 1} = propagationStatus;
        resultDetails{end + 1, 1} = detail;
    end
end

function configureSourceSignal(sourcePortHandle, signalName, mustResolve)
    if nargin < 3 || isempty(mustResolve), mustResolve = true; end
    if mustResolve, resolveValue = 'on'; else, resolveValue = 'off'; end
    set_param(sourcePortHandle, 'Name', signalName, 'MustResolveToSignalObject', resolveValue);
end

function propagationStatus = enablePropagationAfterInternalInport(internalInport)
    portHandles = get_param(internalInport, 'PortHandles');
    if ~isfield(portHandles, 'Outport') || isempty(portHandles.Outport)
        propagationStatus = 'No outport found'; return;
    end
    lineHandle = get_param(portHandles.Outport(1), 'Line');
    if isempty(lineHandle) || any(lineHandle == -1)
        propagationStatus = 'Unconnected'; return;
    end
    enablePropagationOnLine(lineHandle);
    propagationStatus = 'Propagation on';
end

function propagationStatus = enablePropagationAfterSubsystemOutport(externalOutputPortHandle)
    lineHandle = get_param(externalOutputPortHandle, 'Line');
    if isempty(lineHandle) || any(lineHandle == -1)
        propagationStatus = 'Unconnected'; return;
    end
    enablePropagationOnLine(lineHandle);
    propagationStatus = 'Propagation on';
end

function enablePropagationOnLine(lineHandle)
    if isempty(lineHandle) || any(lineHandle == -1)
        return;
    end
    for k = 1:numel(lineHandle)
        h = lineHandle(k);
        if h > 0 && ishandle(h)
            try
                % Clear any explicit string so propagation takes over
                set_param(h, 'Name', '');
                % Turn on signal propagation display
                set_param(h, 'ShowPropagatedSignals', 'on');
            catch
            end
        end
    end
end

function [location, skipResolve] = ensureSignalObject(modelName, signalName)
    skipResolve = false;
    modelWorkspace = get_param(modelName, 'ModelWorkspace');
    dataDictionary = strtrim(get_param(modelName, 'DataDictionary'));

    if modelWorkspace.hasVariable(signalName)
        val = modelWorkspace.evalin(signalName);
        if isa(val, 'Simulink.Signal')
            modelWorkspace.clear(signalName);
        else
            location = 'Model Workspace Parameter';
            skipResolve = true;
            return;
        end
    end

    if ~isempty(dataDictionary)
        try
            dictObj = Simulink.data.dictionary.open(dataDictionary);
            sec = getSection(dictObj, 'Design Data');
            if sec.entryExists(signalName)
                entry = getEntry(sec, signalName);
                val = entry.getValue();
                if isa(val, 'Simulink.Signal')
                    location = sprintf('data dictionary "%s"', dataDictionary);
                else
                    location = sprintf('data dictionary "%s" (Existing parameter)', dataDictionary);
                    skipResolve = true;
                end
            else
                sec.addEntry(signalName, Simulink.Signal);
                location = sprintf('data dictionary "%s"', dataDictionary);
            end
            return;
        catch
        end
    end

    baseExists = evalin('base', sprintf('exist(''%s'', ''var'')', signalName));
    if baseExists
        val = evalin('base', signalName);
        if isa(val, 'Simulink.Signal')
            location = 'Base Workspace';
        else
            location = 'Base Workspace (Existing parameter)';
            skipResolve = true;
        end
    else
        evalin('base', sprintf('%s = Simulink.Signal;', signalName));
        location = 'Base Workspace';
    end
end

function persistSignalObjectChanges(modelName)
    dataDictionary = strtrim(get_param(modelName, 'DataDictionary'));
    if ~isempty(dataDictionary)
        try
            dictObj = Simulink.data.dictionary.open(dataDictionary);
            saveChanges(dictObj);
        catch
        end
    end
end

function saveModelIfRequired(modelName)
    dataDictionary = strtrim(get_param(modelName, 'DataDictionary'));
    if isempty(dataDictionary)
        try save_system(modelName); catch; end
    end
end

function [isValid, message] = validateSignalName(signalName, portType)
    isValid = isvarname(signalName);
    if ~isValid
        message = sprintf('"%s" is not a valid MATLAB identifier.', signalName);
    else
        message = '';
    end
end

function portNumber = getNumericPortNumber(block)
    portNumber = str2double(get_param(block, 'Port'));
end

function report = createEmptyResultTable()
    report = table(zeros(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), ...
        strings(0, 1), strings(0, 1), ...
        'VariableNames', {'Port', 'Direction', 'Signal', 'Status', 'Propagation', 'Details'});
end