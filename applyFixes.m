function results = applyFixes(issues, modelsFolder, progressFcn)
%APPLYFIXES Applies the selected fix to each issue.
%
%   results = applyFixes(issues, modelsFolder)
%   results = applyFixes(issues, modelsFolder, progressFcn)
%
%   results(i).Success  — true/false
%   results(i).Message  — Description of what was done

    if nargin < 3 || isempty(progressFcn)
        progressFcn = @(pct, msg) fprintf('[%.0f%%] %s\n', pct*100, msg);
    end

    results = struct('Success', {}, 'Message', {});
    fixable = issues(~strcmp({issues.FixMethod}, 'none'));
    nFixes = numel(fixable);

    if nFixes == 0
        results(1) = struct('Success', true, 'Message', 'No fixable issues.');
        return;
    end

    for i = 1:nFixes
        issue = fixable(i);
        progressFcn(i/nFixes, sprintf('Fixing %d/%d: %s [%s]', ...
            i, nFixes, issue.Model, issue.FixMethod));

        try
            switch issue.FixMethod
                case 'InsertUnitDelay'
                    [ok, msg] = fixSampleTimeByUnitDelay(issue.FixData, modelsFolder);

                case 'SetOutportConstant'
                    [ok, msg] = fixSampleTimeByConstant(issue.FixData, modelsFolder);

                case 'SyncToMaster'
                    [ok, msg] = fixSLDDBySync(issue.FixData);

                case 'MatchParent'
                    [ok, msg] = fixConfigByMatch(issue.FixData, modelsFolder);

                otherwise
                    ok = false;
                    msg = sprintf('Unknown fix method: %s', issue.FixMethod);
            end
        catch fixErr
            ok = false;
            msg = sprintf('Fix failed: %s', fixErr.message);
        end

        results(end+1) = struct('Success', ok, 'Message', msg);
    end

    progressFcn(1, sprintf('Applied %d fixes. %d succeeded, %d failed.', ...
        nFixes, sum([results.Success]), sum(~[results.Success])));
end

% =====================================================================
% Fix 1: Insert Unit Delay between Constant and Outport
% =====================================================================
function [ok, msg] = fixSampleTimeByUnitDelay(fixData, modelsFolder)
    ok = false;
    modelName = fixData.ModelName;
    outportPath = fixData.OutportPath;
    driverPath = fixData.DriverBlockPath;

    modelFile = findModelFileOnDisk(modelsFolder, modelName);
    if isempty(modelFile)
        msg = sprintf('Model file not found: %s', modelName);
        return;
    end

    openedByUs = false;
    if ~bdIsLoaded(modelName)
        load_system(modelFile);
        openedByUs = true;
    end

    try
        portHandles = get_param(outportPath, 'PortHandles');
        inportHandle = portHandles.Inport;
        lineHandle = get_param(inportHandle, 'LineHandle');

        driverPos = get_param(driverPath, 'Position');
        outportPos = get_param(outportPath, 'Position');

        udX = round((driverPos(3) + outportPos(1)) / 2) - 20;
        udY = round(outportPos(2)) - 10;
        udPos = [udX, udY, udX + 40, udY + 20];

        udName = 'UnitDelay_Fix';
        suffix = 1;
        while ~isempty(find_system(modelName, 'SearchDepth', 1, 'Name', udName))
            suffix = suffix + 1;
            udName = sprintf('UnitDelay_Fix_%d', suffix);
        end

        add_block('built-in/UnitDelay', [modelName '/' udName], 'Position', udPos);
        delete_line(lineHandle);
        add_line(modelName, [driverPath '/1'], [udName '/1'], 'autorouting', 'on');
        add_line(modelName, [udName '/1'], [outportPath '/1'], 'autorouting', 'on');

        save_system(modelName);
        ok = true;
        msg = sprintf('Inserted Unit Delay "%s" in model "%s".', udName, modelName);
    catch fixErr
        msg = sprintf('Failed to insert Unit Delay: %s', fixErr.message);
    end

    if openedByUs
        try close_system(modelName, 0); catch, end
    end
end

% =====================================================================
% Fix 2: Set Outport Sample Time to Constant (Inf)
% =====================================================================
function [ok, msg] = fixSampleTimeByConstant(fixData, modelsFolder)
    ok = false;
    modelName = fixData.ModelName;
    outportPath = fixData.OutportPath;

    modelFile = findModelFileOnDisk(modelsFolder, modelName);
    if isempty(modelFile)
        msg = sprintf('Model file not found: %s', modelName);
        return;
    end

    openedByUs = false;
    if ~bdIsLoaded(modelName)
        load_system(modelFile);
        openedByUs = true;
    end

    try
        set_param(outportPath, 'SampleTime', 'Inf');
        save_system(modelName);
        ok = true;
        msg = sprintf('Set Outport "%s" sample time to Inf (constant) in model "%s".', ...
            get_param(outportPath, 'Name'), modelName);
    catch fixErr
        msg = sprintf('Failed to set sample time: %s', fixErr.message);
    end

    if openedByUs
        try close_system(modelName, 0); catch, end
    end
end

% =====================================================================
% Fix 3: Sync SLDD Symbol to Master Dictionary
% =====================================================================
function [ok, msg] = fixSLDDBySync(fixData)
    ok = false;
    symName = fixData.Symbol;
    defs = fixData.Definitions;
    masterIdx = fixData.MasterIndex;

    masterDef = defs(masterIdx);
    masterMin = masterDef.Min;
    masterMax = masterDef.Max;
    fixedCount = 0;
    failCount = 0;

    for k = 1:numel(defs)
        if k == masterIdx, continue; end

        targetDictPath = defs(k).DictPath;
        try
            dictObj = Simulink.data.dictionary.open(targetDictPath);
            dSect = getSection(dictObj, 'Design Data');
            entries = find(dSect, symName);

            if ~isempty(entries)
                entryObj = entries{1};
                symValue = getValue(entryObj);

                if isobject(symValue)
                    if isprop(symValue, 'Min'), symValue.Min = masterMin; end
                    if isprop(symValue, 'Max'), symValue.Max = masterMax; end
                elseif isstruct(symValue)
                    if isfield(symValue, 'Min'), symValue.Min = masterMin; end
                    if isfield(symValue, 'Max'), symValue.Max = masterMax; end
                end

                setValue(entryObj, symValue);
                saveChanges(dictObj);
                fixedCount = fixedCount + 1;
            end
            close(dictObj);
        catch fixErr
            failCount = failCount + 1;
        end
    end

    if failCount == 0
        ok = true;
        msg = sprintf('Synced "%s" Min/Max to %d dictionaries (master: %s).', ...
            symName, fixedCount, masterDef.DictName);
    else
        ok = false;
        msg = sprintf('Synced %d dictionaries but %d failed for "%s".', ...
            fixedCount, failCount, symName);
    end
end

% =====================================================================
% Fix 4: Match Config Parameters to Parent
% =====================================================================
function [ok, msg] = fixConfigByMatch(fixData, modelsFolder)
    ok = false;
    modelName = fixData.ModelName;
    paramName = fixData.ParamName;
    targetValue = fixData.TargetValue;

    modelFile = findModelFileOnDisk(modelsFolder, modelName);
    if isempty(modelFile)
        msg = sprintf('Model file not found: %s', modelName);
        return;
    end

    openedByUs = false;
    if ~bdIsLoaded(modelName)
        load_system(modelFile);
        openedByUs = true;
    end

    try
        set_param(modelName, paramName, targetValue);
        save_system(modelName);
        ok = true;
        msg = sprintf('Set "%s" = "%s" in model "%s".', paramName, targetValue, modelName);
    catch fixErr
        msg = sprintf('Failed to set config: %s', fixErr.message);
    end

    if openedByUs
        try close_system(modelName, 0); catch, end
    end
end

% =====================================================================
% Helper
% =====================================================================
function modelFile = findModelFileOnDisk(modelsFolder, modelName)
    modelFile = '';
    candidates = dir(fullfile(modelsFolder, '**', [modelName '.slx']));
    if isempty(candidates)
        candidates = dir(fullfile(modelsFolder, '**', [modelName '.mdl']));
    end
    if ~isempty(candidates)
        modelFile = fullfile(candidates(1).folder, candidates(1).name);
    end
end