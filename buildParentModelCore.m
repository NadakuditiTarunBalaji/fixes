function result = buildParentModelCore(modelsFolder, selectedModels, targetModelName, options)
%BUILDPARENTMODELCORE Generates a parent Simulink model containing Model Reference
% blocks with automated dynamic alignment and optional subsystem wrapping.

% ---------------------------------------------------------------- Defaults
if nargin < 4 || isempty(options)
    options = struct();
end
options = fillDefaults(options, struct( ...
    'OutputFolder',                 '', ...
    'Overwrite',                    false, ...
    'BackupExisting',               true, ...
    'CaseInsensitiveMatch',         true, ...
    'ConfigParameters',             {{'UseDivisionForNetSlopeComputation'}}, ...
    'CloseReferencedModels',        true, ...
    'WrapInSubsystem',              false, ...
    'TidyLayout',                   true, ...
    'ConnectionMethod',             'lines', ...
    'Layout',                       'vertical', ...
    'ColorBlocks',                  false, ...
    'AutoDelayFeedback',            false, ...
    'AllowMultipleInstances',       true, ...   
    'ForceInheritedSampleTimes',    false, ...   
    'BlockSpacing',                 100, ...
    'FromModelGap',                 [], ...
    'ModelGotoGap',                 [], ...
    'FromToDelayGap',               [], ...
    'ModelToModelGap',              [], ...
    'PreviewOnly',                  false, ...
    'ProgressFcn',                  @(~, ~) [], ...
    'CancelRequestedFcn',           @false));

progressFcn = options.ProgressFcn;
cancelFcn = options.CancelRequestedFcn;
caseInsensitive = logical(options.CaseInsensitiveMatch);
connectionMethod = lower(char(options.ConnectionMethod));
if ~ismember(connectionMethod, {'lines', 'fromgoto'})
    connectionMethod = 'lines';
end
layoutStyle = lower(char(options.Layout));
if ~ismember(layoutStyle, {'vertical', 'horizontal'})
    layoutStyle = 'vertical';
end
colorBlocks = logical(options.ColorBlocks);
autoDelayFeedback = logical(options.AutoDelayFeedback);
blockSpacing = max(55, round(double(options.BlockSpacing)));

fromModelGap = blockSpacing;
if ~isempty(options.FromModelGap), fromModelGap = max(20, round(double(options.FromModelGap))); end
modelGotoGap = blockSpacing;
if ~isempty(options.ModelGotoGap), modelGotoGap = max(20, round(double(options.ModelGotoGap))); end
fromToDelayGap = round(blockSpacing * 0.40);
if ~isempty(options.FromToDelayGap), fromToDelayGap = max(10, round(double(options.FromToDelayGap))); end

result = struct( ...
    'Success',              false, ...
    'Cancelled',            false, ...
    'PreviewOnly',          logical(options.PreviewOnly), ...
    'TargetModel',          '', ...
    'OutputFile',           '', ...
    'Models',               struct('Name', {}, 'Path', {}, 'InputNames', {}, 'OutputNames', {}), ...
    'InternalConnections',  struct('SrcModelIndex', {}, 'SrcPortIndex', {}, ...
                                   'DstModelIndex', {}, 'DstPortIndex', {}, ...
                                   'SrcModel', {}, 'SrcPort', {}, ...
                                   'DstModel', {}, 'DstPort', {}), ...
    'RootInputs',           struct('Name', {}, 'DestinationModels', {}, ...
                                   'DestinationPorts', {}, 'DestinationModelIndexes', {}, ...
                                   'DestinationPortIndexes', {}), ...
    'RootOutputs',          struct('Name', {}, 'SourceModel', {}, 'SourcePort', {}, ...
                                   'SourceModelIndex', {}, 'SourcePortIndex', {}), ...
    'ConfigParamNames',     {{}}, ...
    'ConfigParamValues',    {{}}, ...
    'Warnings',             {{}}, ...
    'Notes',                {{}}, ...
    'Counts',               struct('Internal', 0, 'RootInputs', 0, 'RootOutputs', 0), ...
    'SubsystemName',        '', ...
    'BackupFile',           '');

% ------------------------------------------------------------ Validate Inputs
modelsFolder = char(modelsFolder);
if ~isfolder(modelsFolder)
    error('buildParentModelCore:InvalidFolder', 'The models folder does not exist: %s', modelsFolder);
end

if ischar(selectedModels)
    selectedModels = {selectedModels};
elseif isstring(selectedModels)
    selectedModels = cellstr(selectedModels(:));
end
selectedModels = cellfun(@char, selectedModels, 'UniformOutput', false);
selectedModels = cellfun(@(s) strtrim(s), selectedModels, 'UniformOutput', false);
selectedModels = regexprep(selectedModels, '\.(slx|mdl)$', '', 'ignorecase');
selectedModels = selectedModels(~cellfun('isempty', selectedModels));
if isempty(selectedModels)
    error('buildParentModelCore:NoModelsSelected', 'Select at least one referenced model.');
end
numModels = numel(selectedModels);

targetModel = char(targetModelName);
targetModel = strtrim(targetModel);
targetModel = regexprep(targetModel, '\.(slx|mdl)$', '', 'ignorecase');
if isempty(targetModel), targetModel = 'GeneratedReferenceModel'; end
targetModel = matlab.lang.makeValidName(targetModel);
result.TargetModel = targetModel;

if any(strcmpi(selectedModels, targetModel))
    error('buildParentModelCore:NameClash', ...
        'The generated model name "%s" must differ from the referenced-model names.', targetModel);
end

if isempty(options.OutputFolder)
    outputFolder = modelsFolder;
else
    outputFolder = char(options.OutputFolder);
end
if ~isfolder(outputFolder)
    error('buildParentModelCore:InvalidOutputFolder', 'The output folder does not exist: %s', outputFolder);
end

targetModelFile = fullfile(outputFolder, [targetModel '.slx']);
result.OutputFile = targetModelFile;

if ~result.PreviewOnly && isfile(targetModelFile) && ~options.Overwrite
    error('buildParentModelCore:FileExists', ...
        'The model file already exists:\n%s\n\nOverwrite it (or choose a different name).', targetModelFile);
end

% --------------------------------------------------------------- Discovery
progressFcn(0.05, 'Discovering model files...');
availableModels = discoverModelFiles(modelsFolder);
if isempty(availableModels)
    error('buildParentModelCore:NoModelsFound', 'No .slx or .mdl files were found under:\n%s', modelsFolder);
end

modelNames = cell(numModels, 1);
modelPaths = cell(numModels, 1);
for modelIndex = 1:numModels
    requestedName = selectedModels{modelIndex};
    matchIndexes = find(strcmpi(availableModels.names, requestedName));
    if isempty(matchIndexes)
        error('buildParentModelCore:ModelNotFound', 'Referenced model "%s" was not found.', requestedName);
    end
    if numel(matchIndexes) > 1
        error('buildParentModelCore:DuplicateModelName', 'Multiple files named "%s" were found.', requestedName);
    end
    modelNames{modelIndex} = availableModels.names{matchIndexes(1)};
    modelPaths{modelIndex} = availableModels.paths{matchIndexes(1)};
end

% ------------------------------------------------------------ Load Models
progressFcn(0.15, 'Loading referenced models...');
searchPath = genpath(modelsFolder);
if ~isempty(searchPath), addpath(searchPath); end

loadedByUs = {};
try
    for modelIndex = 1:numModels
        if ~bdIsLoaded(modelNames{modelIndex})
            load_system(modelPaths{modelIndex});
            loadedByUs{end + 1} = modelNames{modelIndex}; %#ok<AGROW>
        end
        
        if options.AllowMultipleInstances
            try
                if ~strcmp(get_param(modelNames{modelIndex}, 'ModelReferenceNumInstancesAllowed'), 'Multi')
                    set_param(modelNames{modelIndex}, 'ModelReferenceNumInstancesAllowed', 'Multi');
                end
            catch
            end
        end
    end
catch loadError
    closeLoadedModels(loadedByUs);
    error('buildParentModelCore:ModelLoadFailed', ...
        'Could not load model %s.\n\nDetails:\n%s', modelPaths{modelIndex}, errorChainText(loadError));
end

% =========================================================================
% OPTIONAL: FORCE INHERITED SAMPLE TIMES (-1) ACROSS CHILD MODELS
% =========================================================================
if options.ForceInheritedSampleTimes
    progressFcn(0.20, 'Scanning & enforcing inherited sample times (-1)...');
    
    allChanges = {};
    for mIdx = 1:numModels
        allChanges = [allChanges; collectSampleTimeChanges(modelNames{mIdx})]; %#ok<AGROW>
    end
    
    if isempty(allChanges)
        result.Notes{end + 1} = '================== SAMPLE TIME CHANGES ==================';
        result.Notes{end + 1} = 'No blocks required sample-time change (all already at -1 or inherited).';
        result.Notes{end + 1} = '=========================================================';
    else
        result.Notes{end + 1} = '================== SAMPLE TIME CHANGES ==================';
        for cIdx = 1:numel(allChanges)
            ch = allChanges{cIdx};
            logLine = sprintf('[%s] %s (%s) ''%s'' -> ''-1''', ...
                ch.ModelName, ch.BlockPath, ch.BlockType, ch.OldValue);
            result.Notes{end + 1} = logLine; %#ok<AGROW>
        end
        summaryLine = sprintf('Total: %d block(s) changed to SampleTime = -1', numel(allChanges));
        result.Notes{end + 1} = summaryLine;
        result.Notes{end + 1} = '=========================================================';
        
        % Apply changes to child models
        for cIdx = 1:numel(allChanges)
            ch = allChanges{cIdx};
            try
                set_param(ch.BlockPath, 'SampleTime', '-1');
            catch applyErr
                result.Warnings{end + 1} = sprintf( ...
                    'Failed to set SampleTime on %s: %s', ch.BlockPath, applyErr.message); %#ok<AGROW>
            end
        end
        
        % Save dirty child models
        for mIdx = 1:numModels
            mdlName = modelNames{mIdx};
            if bdIsLoaded(mdlName) && bdIsDirty(mdlName)
                try
                    save_system(mdlName);
                catch saveErr
                    result.Warnings{end + 1} = sprintf( ...
                        'Failed to save child model "%s": %s', mdlName, saveErr.message); %#ok<AGROW>
                end
            end
        end
    end
end

parentCreated = false;
try
    % ---------------------------------------------------- Configuration
    progressFcn(0.3, 'Checking configuration parameters...');
    configParamNames = options.ConfigParameters;
    if ischar(configParamNames), configParamNames = {configParamNames};
    elseif isstring(configParamNames), configParamNames = cellstr(configParamNames(:)); end
    
    configParamNames = configParamNames(:);
    configParamValues = cell(size(configParamNames));
    configProblems = {};

    for paramIndex = 1:numel(configParamNames)
        parameter = char(configParamNames{paramIndex});
        values = cell(1, numModels);
        readableFlags = false(1, numModels);
        
        for modelIndex = 1:numModels
            [val, ok] = readConfigParamSafe(modelNames{modelIndex}, parameter);
            if ok
                values{modelIndex} = val;
                readableFlags(modelIndex) = true;
            else
                configProblems{end + 1} = sprintf( ...
                    'Parameter "%s" not available in model "%s" (skipped).', ...
                    parameter, modelNames{modelIndex}); %#ok<AGROW>
            end
        end
        
        if ~any(readableFlags), continue; end
        
        readableValues = values(readableFlags);
        if numel(unique(readableValues)) > 1
            detailParts = cell(1, sum(readableFlags));
            idx = 0;
            for modelIndex = 1:numModels
                if readableFlags(modelIndex)
                    idx = idx + 1;
                    detailParts{idx} = sprintf('%s = %s', modelNames{modelIndex}, values{modelIndex});
                end
            end
            configProblems{end + 1} = sprintf( ...
                '"%s" differs across models: %s', ...
                parameter, strjoin(detailParts, ', ')); %#ok<AGROW>
        end
        
        configParamNames{paramIndex} = parameter;
        configParamValues{paramIndex} = readableValues{1};
    end

    if ~isempty(configProblems)
        for wIdx = 1:numel(configProblems)
            result.Warnings{end + 1} = configProblems{wIdx}; %#ok<AGROW>
        end
    end

    okParams = ~cellfun('isempty', configParamValues);
    result.ConfigParamNames = configParamNames(okParams);
    result.ConfigParamValues = configParamValues(okParams);

    % --------------------------------------------------------- Interfaces
    progressFcn(0.4, 'Reading model interfaces...');
    modelInfo = struct('Name', modelNames, 'Path', modelPaths, ...
        'InputNames', cell(numModels, 1), 'OutputNames', cell(numModels, 1));

    for modelIndex = 1:numModels
        [inputNames, outputNames] = getRootPortNames(modelNames{modelIndex});
        modelInfo(modelIndex).InputNames = inputNames;
        modelInfo(modelIndex).OutputNames = outputNames;
    end
    result.Models = modelInfo;

    % ---------------------------------------------------------------- Plan
    progressFcn(0.5, 'Planning connections...');
    inputConnected = cell(numModels, 1);
    for modelIndex = 1:numModels
        inputConnected{modelIndex} = false(numel(modelInfo(modelIndex).InputNames), 1);
    end

    internalConnections = result.InternalConnections;
    selfMatchNotes = {};

    for sourceIndex = 1:numModels
        outputs = modelInfo(sourceIndex).OutputNames;
        inputs = modelInfo(sourceIndex).InputNames;
        for outputIndex = 1:numel(outputs)
            outputKey = normKey(outputs{outputIndex}, caseInsensitive);
            for destinationIndex = 1:numModels
                if destinationIndex == sourceIndex, continue; end
                destinationInputs = modelInfo(destinationIndex).InputNames;
                for inputIndex = 1:numel(destinationInputs)
                    if inputConnected{destinationIndex}(inputIndex), continue; end
                    if strcmp(normKey(destinationInputs{inputIndex}, caseInsensitive), outputKey)
                        inputConnected{destinationIndex}(inputIndex) = true;
                        internalConnections(end + 1) = struct( ...
                            'SrcModelIndex', sourceIndex, 'SrcPortIndex',  outputIndex, ...
                            'DstModelIndex', destinationIndex, 'DstPortIndex',  inputIndex, ...
                            'SrcModel',      modelInfo(sourceIndex).Name, 'SrcPort', outputs{outputIndex}, ...
                            'DstModel',      modelInfo(destinationIndex).Name, 'DstPort', destinationInputs{inputIndex}); %#ok<AGROW>
                    end
                end
            end
        end
        for outputIndex = 1:numel(outputs)
            outputKey = normKey(outputs{outputIndex}, caseInsensitive);
            for inputIndex = 1:numel(inputs)
                if strcmp(normKey(inputs{inputIndex}, caseInsensitive), outputKey)
                    note = sprintf('Note: model "%s" has input and output named "%s" - self-connections skipped.', ...
                        modelInfo(sourceIndex).Name, outputs{outputIndex});
                    if ~any(strcmp(selfMatchNotes, note))
                        selfMatchNotes{end + 1} = note; %#ok<AGROW>
                    end
                end
            end
        end
    end

    result.InternalConnections = internalConnections;
    result.Counts.Internal = numel(internalConnections);

    flatOutputs = {};
    flatOwners = zeros(0, 1);
    for modelIndex = 1:numModels
        outputs = modelInfo(modelIndex).OutputNames(:);
        flatOutputs = [flatOutputs; outputs]; %#ok<AGROW>
        flatOwners = [flatOwners; repmat(modelIndex, numel(outputs), 1)]; %#ok<AGROW>
    end

    rootInputs = result.RootInputs;
    groupKeys = {};
    for destinationIndex = 1:numModels
        destinationInputs = modelInfo(destinationIndex).InputNames;
        for inputIndex = 1:numel(destinationInputs)
            if inputConnected{destinationIndex}(inputIndex), continue; end
            key = normKey(destinationInputs{inputIndex}, caseInsensitive);
            groupPosition = find(strcmp(groupKeys, key), 1);
            if isempty(groupPosition)
                groupKeys{end + 1} = key; %#ok<AGROW>
                rootInputs(end + 1) = struct('Name', destinationInputs{inputIndex}, ...
                    'DestinationModels', {{}}, 'DestinationPorts', {{}}, ...
                    'DestinationModelIndexes', [], 'DestinationPortIndexes', []); %#ok<AGROW>
                groupPosition = numel(rootInputs);
            end
            rootInputs(groupPosition).DestinationModels{end + 1} = modelInfo(destinationIndex).Name; %#ok<AGROW>
            rootInputs(groupPosition).DestinationPorts{end + 1} = destinationInputs{inputIndex}; %#ok<AGROW>
            rootInputs(groupPosition).DestinationModelIndexes(end + 1) = destinationIndex; %#ok<AGROW>
            rootInputs(groupPosition).DestinationPortIndexes(end + 1) = inputIndex; %#ok<AGROW>
        end
    end
    result.RootInputs = rootInputs;
    result.Counts.RootInputs = numel(rootInputs);

    rootOutputs = result.RootOutputs;
    usedTopNames = {};
    for sourceIndex = 1:numModels
        outputs = modelInfo(sourceIndex).OutputNames;
        for outputIndex = 1:numel(outputs)
            requestedName = outputs{outputIndex};
            if any(strcmp(usedTopNames, requestedName))
                requestedName = sprintf('%s_%s', modelInfo(sourceIndex).Name, outputs{outputIndex});
            end
            baseName = requestedName;
            suffix = 2;
            while any(strcmp(usedTopNames, requestedName))
                requestedName = sprintf('%s_%d', baseName, suffix);
                suffix = suffix + 1;
            end
            usedTopNames{end + 1} = requestedName; %#ok<AGROW>
            rootOutputs(end + 1) = struct('Name', requestedName, 'SourceModel', modelInfo(sourceIndex).Name, ...
                'SourcePort', outputs{outputIndex}, 'SourceModelIndex', sourceIndex, 'SourcePortIndex', outputIndex); %#ok<AGROW>
        end
    end
    result.RootOutputs = rootOutputs;
    result.Counts.RootOutputs = numel(rootOutputs);
    result.Notes = [result.Notes; selfMatchNotes];

    if cancelFcn()
        result.Cancelled = true;
        if options.CloseReferencedModels, closeLoadedModels(loadedByUs); end
        return;
    end

    % ------------------------------------------------------------- Preview
    if result.PreviewOnly
        if options.CloseReferencedModels, closeLoadedModels(loadedByUs); end
        result.Success = true;
        progressFcn(1, 'Preview complete.');
        return;
    end

    % --------------------------------------------------------------- Build
    progressFcn(0.6, 'Creating the parent model...');
    if isfile(targetModelFile) && options.BackupExisting
        backupFile = [targetModelFile '.bak'];
        movefile(targetModelFile, backupFile);
        result.BackupFile = backupFile;
    end

    if bdIsLoaded(targetModel), close_system(targetModel, 0); end

    new_system(targetModel);
    parentCreated = true;
    open_system(targetModel);
    set_param(targetModel, 'Location', [100 100 1500 850]);

    for paramIndex = 1:numel(result.ConfigParamNames)
        try
            set_param(targetModel, result.ConfigParamNames{paramIndex}, result.ConfigParamValues{paramIndex});
        catch
        end
    end

    % =========================================================================
    % PARENT-LEVEL SAMPLE TIME CONFIGURATION
    % =========================================================================
    set_param(targetModel, 'SolverType', 'Fixed-step');
    set_param(targetModel, 'Solver', 'FixedStepDiscrete');
    set_param(targetModel, 'SolverMode', 'SingleTasking');
    set_param(targetModel, 'AutoInsertRateTranBlk', 'off');

    detectedRates = [];
    for mIdx = 1:numModels
        try
            childStep = str2double(get_param(modelNames{mIdx}, 'FixedStep'));
            if ~isnan(childStep) && childStep > 0
                detectedRates(end+1) = childStep; %#ok<AGROW>
            end
        catch
        end
    end

    if ~isempty(detectedRates)
        baseStep = detectedRates(1);
        for r = 2:numel(detectedRates)
            baseStep = gcd(round(baseStep*1e6), round(detectedRates(r)*1e6)) / 1e6;
        end
        set_param(targetModel, 'FixedStep', num2str(baseStep));
    else
        set_param(targetModel, 'FixedStep', '0.001');
    end

    % Suppress all diagnostic halts & warnings
    safeParams = { ...
        'InvalidRootInportConnection',          'none', ...
        'InvalidRootOutportConnection',         'none', ...
        'SingleTaskRateTransMsg',               'none', ...
        'MultiTaskRateTransMsg',                'none', ...
        'InconsistentSampleTimesMsg',           'none', ...
        'ModelReferenceCSMismatchMessage',      'none', ...
        'ModelReferenceVersionMismatchMessage', 'none', ...
        'ModelReferenceIOMsg',                  'none', ...
        'ModelReferenceIOMismatchMessage',      'none', ...
        'ModelReferenceDataLoggingMessage',     'none', ...
        'MultiTaskDSMLog',                      'none', ...
        'MultiTaskCondExecSys',                 'none', ...
        'DiscreteInheritContinuousMsg',         'none', ...
        'InheritedTsInSrcMsg',                  'none', ...
        'TasksWithSamePriorityMsg',             'none'  ...
    };

    for pIdx = 1:2:numel(safeParams)
        try
            set_param(targetModel, safeParams{pIdx}, safeParams{pIdx+1});
        catch
        end
    end

    % ------------------------------------------------ Setup Build Target
    wrapInSub = options.WrapInSubsystem;
    subsystemName = '';
    if wrapInSub
        subsystemName = matlab.lang.makeValidName([targetModel '_Core']);
        result.SubsystemName = subsystemName;
        subBlockPath = [targetModel '/' subsystemName];
        add_block('built-in/Subsystem', subBlockPath);
        Simulink.SubSystem.deleteContents(subBlockPath);
        containerSystem = subBlockPath;
    else
        containerSystem = targetModel;
    end

    globalInportColor = '[0.65,0.90,0.65]';
    globalOutportColor = '[0.95,0.70,0.45]';
    globalFromColor    = '[0.941,0.886,0.808]'; % Hex #f0e2ce (Beige/Cream)


    if strcmp(connectionMethod, 'fromgoto')
        % ============================================================
        % FROM/GOTO MODE (DISAMBIGUATED TAG MAPPING)
        % ============================================================
        progressFcn(0.65, 'Adding Model Reference blocks (From/Goto style)...');
                % Map every output signal to its producing model index for color lookup
        signalSourceModelIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
        for mIdx = 1:numModels
            outs = modelInfo(mIdx).OutputNames;
            for oIdx = 1:numel(outs)
                sKey = normKey(outs{oIdx}, caseInsensitive);
                if ~isKey(signalSourceModelIndex, sKey)
                    signalSourceModelIndex(sKey) = mIdx;
                end
            end
        end

        modelOutputKeys = cell(numModels, 1);
        usedTags = {};

        for modelIndex = 1:numModels
            outputs = modelInfo(modelIndex).OutputNames;
            tags = cell(numel(outputs), 1);
            for outputIndex = 1:numel(outputs)
                sigName = outputs{outputIndex};
                baseTag = safeName(sigName);
                
                key = normKey(sigName, caseInsensitive);
                isDup = false;
                for otherM = 1:numModels
                    if otherM == modelIndex, continue; end
                    if any(strcmp(cellfun(@(s) normKey(s, caseInsensitive), modelInfo(otherM).OutputNames, 'UniformOutput', false), key))
                        isDup = true;
                        break;
                    end
                end
                
                if isDup
                    tag = sprintf('%s_%s', baseTag, safeName(modelInfo(modelIndex).Name));
                else
                    tag = baseTag;
                end
                
                uniqueTag = tag;
                suffix = 2;
                while any(strcmp(usedTags, uniqueTag))
                    uniqueTag = sprintf('%s_%d', tag, suffix);
                    suffix = suffix + 1;
                end
                tags{outputIndex} = uniqueTag;
                usedTags{end + 1} = uniqueTag; %#ok<AGROW>
            end
            modelOutputKeys{modelIndex} = tags;
        end

        longestTagLength = 6;
        for tagIndex = 1:numel(usedTags)
            longestTagLength = max(longestTagLength, numel(usedTags{tagIndex}));
        end
        commonFromGotoWidth = max(100, ceil(longestTagLength * 8.5) + 30);
        
        modelWidth = 260;
        uniformModelH = 140;
        for m = 1:numModels
            nP = max([numel(modelInfo(m).InputNames), numel(modelInfo(m).OutputNames), 1]);
            uniformModelH = max(uniformModelH, (nP + 1) * 36);
        end
        
        fromGap = fromModelGap;
        gotoGap = modelGotoGap;
        delayGap = fromToDelayGap;
        
        tagClearance = 120;
        minModelGap = gotoGap + commonFromGotoWidth + tagClearance + commonFromGotoWidth + fromGap + (delayGap + 40);
        if isempty(options.ModelToModelGap)
            modelToModelGap = max(400, minModelGap);
            verticalModelGap = 100;
        else
            userModelGap = max(50, round(double(options.ModelToModelGap)));
            modelToModelGap = max(minModelGap, userModelGap);
            verticalModelGap = userModelGap;
        end
        
        modelBaseY = 200;
        maxRootGotoW = 100;
        for sIdx = 1:numel(usedTags)
            maxRootGotoW = max(maxRootGotoW, ceil(numel(usedTags{sIdx}) * 8.5) + 30);
        end
        rootClearance = 120;
        modelBaseX = 50 + 35 + 40 + maxRootGotoW + rootClearance + commonFromGotoWidth + (delayGap + 40) + fromGap;

        modelBlockNames = cell(numModels, 1);
        xCursor = modelBaseX;
        yCursor = 80;
        rightMostEdge = 0;
        
        for modelIndex = 1:numModels
            if strcmp(layoutStyle, 'horizontal')
                blockX = xCursor; blockY = modelBaseY;
                xCursor = xCursor + modelWidth + modelToModelGap;
            else
                blockX = modelBaseX; blockY = yCursor;
                yCursor = yCursor + uniformModelH + verticalModelGap;
            end
            blockName = makeUniqueBlockName(containerSystem, modelInfo(modelIndex).Name);
            modelBlockNames{modelIndex} = blockName;
            modelInfo(modelIndex).BlockPos = [blockX, blockY, blockX + modelWidth, blockY + uniformModelH];
            
            add_block('simulink/Ports & Subsystems/Model', [containerSystem '/' blockName], ...
                'ModelName', modelInfo(modelIndex).Name, 'Position', modelInfo(modelIndex).BlockPos);
            if colorBlocks
                set_param([containerSystem '/' blockName], 'BackgroundColor', paletteColor(modelIndex));
            end
            rightMostEdge = max(rightMostEdge, blockX + modelWidth + gotoGap + commonFromGotoWidth);
        end

        progressFcn(0.75, 'Reading the model ports...');
        for modelIndex = 1:numModels
            portHandles = get_param([containerSystem '/' modelBlockNames{modelIndex}], 'PortHandles');
            inHandles = portHandles.Inport(:);
            outHandles = portHandles.Outport(:);
            modelInfo(modelIndex).InputHandles = inHandles;
            modelInfo(modelIndex).OutputHandles = outHandles;
            
            inputPortYs = zeros(numel(inHandles), 1);
            for portIndex = 1:numel(inHandles)
                pPos = get_param(inHandles(portIndex), 'Position'); inputPortYs(portIndex) = pPos(2);
            end
            modelInfo(modelIndex).InputPortYs = inputPortYs;
            
            outputPortYs = zeros(numel(outHandles), 1);
            for portIndex = 1:numel(outHandles)
                pPos = get_param(outHandles(portIndex), 'Position'); outputPortYs(portIndex) = pPos(2);
            end
            modelInfo(modelIndex).OutputPortYs = outputPortYs;
        end

        progressFcn(0.8, 'Adding From/Goto blocks and connections...');
        autoDelayCount = 0;
        fromCountByTag = containers.Map('KeyType', 'char', 'ValueType', 'double');
        gotoCountByTag = containers.Map('KeyType', 'char', 'ValueType', 'double');
        
        for modelIndex = 1:numModels
            blockPos = modelInfo(modelIndex).BlockPos;
            for inputIndex = 1:numel(modelInfo(modelIndex).InputNames)
                sig = modelInfo(modelIndex).InputNames{inputIndex};
                
                tag = safeName(sig);
                isFeedbackLoop = false; % <<< SCOPED PER PORT (PREVENTS LEAKS)
                srcModelIdx = 0; % <<< FIX: Initialize srcModelIdx to 0 for every port

                for connIdx = 1:numel(internalConnections)
                    conn = internalConnections(connIdx);
                    if conn.DstModelIndex == modelIndex && conn.DstPortIndex == inputIndex
                        tag = modelOutputKeys{conn.SrcModelIndex}{conn.SrcPortIndex};
                        if conn.SrcModelIndex >= modelIndex
                            isFeedbackLoop = true;
                        end
                        break;
                    end
                end
                
                % signalY = modelInfo(modelIndex).InputPortYs(inputIndex);

                % fromCounter = 1;
                % if isKey(fromCountByTag, tag), fromCounter = fromCountByTag(tag) + 1; end
                % fromCountByTag(tag) = fromCounter;
                % fromName = makeUniqueBlockName(containerSystem, sprintf('%s_From_%d', tag, fromCounter));
                
                % % ONLY insert UnitDelay if autoDelayFeedback is true AND this is a genuine feedback loop!
                % inputIsFeedback = autoDelayFeedback && isFeedbackLoop;
                
                % if inputIsFeedback
                %     fromRight = blockPos(1) - (fromModelGap + fromToDelayGap + 40);
                % else
                %     fromRight = blockPos(1) - fromGap;
                % end
                % fromLeft = fromRight - commonFromGotoWidth;
                
                % add_block('simulink/Signal Routing/From', [containerSystem '/' fromName], 'GotoTag', tag, ...
                %     'Position', [fromLeft, signalY - 10, fromRight, signalY + 10]);

                % if inputIsFeedback
                %     delayName = makeUniqueBlockName(containerSystem, sprintf('UnitDelay_%d', autoDelayCount + 1));
                %     delayLeft = fromRight + fromToDelayGap;
                    
                %     delayParams = {'Position', [delayLeft, signalY - 10, delayLeft + 40, signalY + 10]};
                %     if options.ForceInheritedSampleTimes
                %         delayParams = [{'SampleTime', '-1'}, delayParams];
                %     end
                    
                %     add_block('built-in/UnitDelay', [containerSystem '/' delayName], delayParams{:});
                %     add_line(containerSystem, [fromName '/1'], [delayName '/1'], 'autorouting', 'off');
                %     add_line(containerSystem, [delayName '/1'], sprintf('%s/%d', modelBlockNames{modelIndex}, inputIndex), 'autorouting', 'off');
                %     autoDelayCount = autoDelayCount + 1;
                % else
                %     add_line(containerSystem, [fromName '/1'], sprintf('%s/%d', modelBlockNames{modelIndex}, inputIndex), 'autorouting', 'off');
                % end
                signalY = modelInfo(modelIndex).InputPortYs(inputIndex);

                fromCounter = 1;
                if isKey(fromCountByTag, tag), fromCounter = fromCountByTag(tag) + 1; end
                fromCountByTag(tag) = fromCounter;
                fromName = makeUniqueBlockName(containerSystem, sprintf('%s_From_%d', tag, fromCounter));
                
                inputIsFeedback = autoDelayFeedback && isFeedbackLoop;
                
                if inputIsFeedback
                    fromRight = blockPos(1) - (fromModelGap + fromToDelayGap + 40);
                else
                    fromRight = blockPos(1) - fromGap;
                end
                fromLeft = fromRight - commonFromGotoWidth;
                
                add_block('simulink/Signal Routing/From', [containerSystem '/' fromName], 'GotoTag', tag, ...
                    'Position', [fromLeft, signalY - 10, fromRight, signalY + 10]);

                % Look up source model index for coloring From & UnitDelay
                srcModelIdx = 0;
                sigKey = normKey(sig, caseInsensitive);
                if isKey(signalSourceModelIndex, sigKey)
                    srcModelIdx = signalSourceModelIndex(sigKey);
                end

                if colorBlocks
                    if srcModelIdx > 0
                        set_param([containerSystem '/' fromName], 'BackgroundColor', paletteColor(srcModelIdx));
                    else
                        set_param([containerSystem '/' fromName], 'BackgroundColor', globalFromColor);
                    end
                end

                if inputIsFeedback
                    delayName = makeUniqueBlockName(containerSystem, sprintf('UnitDelay_%d', autoDelayCount + 1));
                    delayLeft = fromRight + fromToDelayGap;
                    
                    delayParams = {'Position', [delayLeft, signalY - 10, delayLeft + 40, signalY + 10]};
%                     if options.ForceInheritedSampleTimes
                    delayParams = [{'SampleTime', '-1'}, delayParams];
%                     end
                    
                    add_block('built-in/UnitDelay', [containerSystem '/' delayName], delayParams{:});
                    
                    if colorBlocks && srcModelIdx > 0
                        set_param([containerSystem '/' delayName], 'BackgroundColor', paletteColor(srcModelIdx));
                    end
                    
                    add_line(containerSystem, [fromName '/1'], [delayName '/1'], 'autorouting', 'off');
                    add_line(containerSystem, [delayName '/1'], sprintf('%s/%d', modelBlockNames{modelIndex}, inputIndex), 'autorouting', 'off');
                    autoDelayCount = autoDelayCount + 1;
                else
                    add_line(containerSystem, [fromName '/1'], sprintf('%s/%d', modelBlockNames{modelIndex}, inputIndex), 'autorouting', 'off');
                end
            end

            for outputIndex = 1:numel(modelInfo(modelIndex).OutputNames)
                tag = modelOutputKeys{modelIndex}{outputIndex};
                signalY = modelInfo(modelIndex).OutputPortYs(outputIndex);

                gotoLeft = blockPos(3) + gotoGap;
                gotoCounter = 1;
                if isKey(gotoCountByTag, tag), gotoCounter = gotoCountByTag(tag) + 1; end
                gotoCountByTag(tag) = gotoCounter;
                gotoName = makeUniqueBlockName(containerSystem, sprintf('%s_Goto_%d', tag, gotoCounter));
                
                add_block('simulink/Signal Routing/Goto', [containerSystem '/' gotoName], 'GotoTag', tag, ...
                    'Position', [gotoLeft, signalY - 10, gotoLeft + commonFromGotoWidth, signalY + 10]);
                if colorBlocks
                    set_param([containerSystem '/' gotoName], 'BackgroundColor', paletteColor(modelIndex));
                end
                add_line(containerSystem, sprintf('%s/%d', modelBlockNames{modelIndex}, outputIndex), [gotoName '/1'], 'autorouting', 'off');
            end
        end

        progressFcn(0.88, 'Adding global inputs and outputs...');
        for g = 1:numel(rootInputs)
            tag = safeName(rootInputs(g).Name);
            signalY = 50 + g * 36;
            inBlockName = makeUniqueBlockName(containerSystem, tag);
            
            add_block('simulink/Sources/In1', [containerSystem '/' inBlockName], 'Port', num2str(g), ...
                'Position', [50, signalY - 10, 85, signalY + 10]);
            if colorBlocks, set_param([containerSystem '/' inBlockName], 'BackgroundColor', globalInportColor); end
            
            gotoBlockName = makeUniqueBlockName(containerSystem, ['Goto_' tag]);
            globalGotoLeft = 85 + blockSpacing;
            
            add_block('simulink/Signal Routing/Goto', [containerSystem '/' gotoBlockName], 'GotoTag', tag, ...
                'Position', [globalGotoLeft, signalY - 10, globalGotoLeft + commonFromGotoWidth, signalY + 10]);
            
            add_line(containerSystem, [inBlockName '/1'], [gotoBlockName '/1'], 'autorouting', 'off');
        end

        globalFromX = rightMostEdge + max(300, 2 * blockSpacing + 100);
        globalOutX = globalFromX + commonFromGotoWidth + blockSpacing;
        
        % for g = 1:numel(rootOutputs)
        %     prodIdx = rootOutputs(g).SourceModelIndex;
        %     portIdx = rootOutputs(g).SourcePortIndex;
        %     tag = modelOutputKeys{prodIdx}{portIdx};
            
        %     signalY = 50 + g * 36;
        %     fromBlockName = makeUniqueBlockName(containerSystem, ['From_' tag]);
            
        %     add_block('simulink/Signal Routing/From', [containerSystem '/' fromBlockName], 'GotoTag', tag, ...
        %         'Position', [globalFromX, signalY - 10, globalFromX + commonFromGotoWidth, signalY + 10]);
            
        %     outBlockName = makeUniqueBlockName(containerSystem, rootOutputs(g).Name);
        %     add_block('simulink/Sinks/Out1', [containerSystem '/' outBlockName], 'Port', num2str(g), ...
        %         'Position', [globalOutX, signalY - 10, globalOutX + 35, signalY + 10]);
        %     if colorBlocks, set_param([containerSystem '/' outBlockName], 'BackgroundColor', globalOutportColor); end
        %     add_line(containerSystem, [fromBlockName '/1'], [outBlockName '/1'], 'autorouting', 'off');
        % end
        for g = 1:numel(rootOutputs)
            prodIdx = rootOutputs(g).SourceModelIndex;
            portIdx = rootOutputs(g).SourcePortIndex;
            tag = modelOutputKeys{prodIdx}{portIdx};
            
            signalY = 50 + g * 36;
            fromBlockName = makeUniqueBlockName(containerSystem, ['From_' tag]);
            
            add_block('simulink/Signal Routing/From', [containerSystem '/' fromBlockName], 'GotoTag', tag, ...
                'Position', [globalFromX, signalY - 10, globalFromX + commonFromGotoWidth, signalY + 10]);
            
            if colorBlocks
                set_param([containerSystem '/' fromBlockName], 'BackgroundColor', paletteColor(prodIdx));
            end
            
            outBlockName = makeUniqueBlockName(containerSystem, rootOutputs(g).Name);
            add_block('simulink/Sinks/Out1', [containerSystem '/' outBlockName], 'Port', num2str(g), ...
                'Position', [globalOutX, signalY - 10, globalOutX + 35, signalY + 10]);
            if colorBlocks, set_param([containerSystem '/' outBlockName], 'BackgroundColor', globalOutportColor); end
            add_line(containerSystem, [fromBlockName '/1'], [outBlockName '/1'], 'autorouting', 'off');
        end

    else
        % ============================================================
        % DIRECT LINES MODE
        % ============================================================
        progressFcn(0.65, 'Adding Model Reference blocks...');
        modelBlockNames = cell(numModels, 1);
        currentModelY = 80; currentModelX = 450;
        
        for modelIndex = 1:numModels
            maxPorts = max([numel(modelInfo(modelIndex).InputNames), numel(modelInfo(modelIndex).OutputNames), 1]);
            cH = max(160, maxPorts * 36);
            blockName = makeUniqueBlockName(containerSystem, modelInfo(modelIndex).Name);
            modelBlockNames{modelIndex} = blockName;

            if strcmp(layoutStyle, 'horizontal')
                bPos = [currentModelX, currentModelY, currentModelX + 240, currentModelY + cH];
                currentModelX = currentModelX + 240 + 100;
            else
                bPos = [450, currentModelY, 450 + 240, currentModelY + cH];
                currentModelY = currentModelY + cH + 100;
            end

            add_block('simulink/Ports & Subsystems/Model', [containerSystem '/' blockName], ...
                'ModelName', modelInfo(modelIndex).Name, 'Position', bPos);
            if colorBlocks, set_param([containerSystem '/' blockName], 'BackgroundColor', paletteColor(modelIndex)); end
        end

        outportX = currentModelX - 100 + 300;

        for modelIndex = 1:numModels
            pH = get_param([containerSystem '/' modelBlockNames{modelIndex}], 'PortHandles');
            modelInfo(modelIndex).InputHandles = pH.Inport(:);
            modelInfo(modelIndex).OutputHandles = pH.Outport(:);
        end

        progressFcn(0.8, 'Connecting outputs to inputs...');
        autoDelayCount = 0; routeMode = 'on'; if options.TidyLayout, routeMode = 'smart'; end
        
        for cIdx = 1:numel(internalConnections)
            conn = internalConnections(cIdx);
            srcH = modelInfo(conn.SrcModelIndex).OutputHandles(conn.SrcPortIndex);
            dstH = modelInfo(conn.DstModelIndex).InputHandles(conn.DstPortIndex);
            
            if autoDelayFeedback && (conn.SrcModelIndex >= conn.DstModelIndex)
                srcPos = get_param([containerSystem '/' modelBlockNames{conn.SrcModelIndex}], 'Position');
                dstPos = get_param(dstH, 'Position');
                dLeft = round(dstPos(1)) - 40 - blockSpacing;
                if dLeft < srcPos(3) + blockSpacing, dLeft = round((srcPos(3) + dstPos(1)) / 2) - 20; end
                dY = round(dstPos(2));
                dName = makeUniqueBlockName(containerSystem, sprintf('UnitDelay_%d', autoDelayCount + 1));
                
                delayParams = {'Position', [dLeft, dY - 10, dLeft + 40, dY + 10]};
                if options.ForceInheritedSampleTimes
                    delayParams = [{'SampleTime', '-1'}, delayParams];
                end
                
                add_block('built-in/UnitDelay', [containerSystem '/' dName], delayParams{:});
                dPorts = get_param([containerSystem '/' dName], 'PortHandles');
                addLineRouted(containerSystem, routeMode, srcH, dPorts.Inport(1));
                addLineRouted(containerSystem, routeMode, dPorts.Outport(1), dstH);
                autoDelayCount = autoDelayCount + 1;
            else
                addLineRouted(containerSystem, routeMode, srcH, dstH);
            end
        end

        if ~isempty(rootInputs)
            for pos = 1:numel(rootInputs)
                mIdx = rootInputs(pos).DestinationModelIndexes(1);
                pIdx = rootInputs(pos).DestinationPortIndexes(1);
                firstDstH = modelInfo(mIdx).InputHandles(pIdx);
                targetPortPos = get_param(firstDstH, 'Position');
                iY = targetPortPos(2);
                
                iName = makeUniqueBlockName(containerSystem, rootInputs(pos).Name);
                add_block('simulink/Sources/In1', [containerSystem '/' iName], 'Port', num2str(pos), ...
                    'Position', [50, iY - 10, 85, iY + 10]);
                if colorBlocks, set_param([containerSystem '/' iName], 'BackgroundColor', globalInportColor); end
                
                rH = get_param([containerSystem '/' iName], 'PortHandles'); rH = rH.Outport;
                for d = 1:numel(rootInputs(pos).DestinationModelIndexes)
                    mIdx = rootInputs(pos).DestinationModelIndexes(d);
                    pIdx = rootInputs(pos).DestinationPortIndexes(d);
                    addLineRouted(containerSystem, routeMode, rH, modelInfo(mIdx).InputHandles(pIdx));
                end
            end
        end

        if ~isempty(rootOutputs)
            for pos = 1:numel(rootOutputs)
                sModelIdx = rootOutputs(pos).SourceModelIndex;
                sPortIdx = rootOutputs(pos).SourcePortIndex;
                srcPortH = modelInfo(sModelIdx).OutputHandles(sPortIdx);
                srcPortPos = get_param(srcPortH, 'Position');
                oY = srcPortPos(2);

                oName = makeUniqueBlockName(containerSystem, rootOutputs(pos).Name);
                add_block('simulink/Sinks/Out1', [containerSystem '/' oName], 'Port', num2str(pos), ...
                    'Position', [outportX, oY - 10, outportX + 35, oY + 10]);
                if colorBlocks, set_param([containerSystem '/' oName], 'BackgroundColor', globalOutportColor); end
                
                sPort = sprintf('%s/%d', modelBlockNames{sModelIdx}, sPortIdx);
                dPort = sprintf('%s/1', oName);
                addLineRouted(containerSystem, routeMode, sPort, dPort);
            end
        end
    end

    % ------------------------------------------------ Outer Subsystem Setup
    if wrapInSub
        progressFcn(0.95, 'Aligning Root Inports and Outports to Subsystem...');
        
        subBlockPath = [targetModel '/' subsystemName];
        ph = get_param(subBlockPath, 'PortHandles');
        nSubIn = numel(ph.Inport);
        nSubOut = numel(ph.Outport);
        
        subHeight = max(160, (max([nSubIn, nSubOut, 1]) + 1) * 38);
        subWidth = 260;
        subX = 450;
        subY = 150;
        subPos = [subX, subY, subX + subWidth, subY + subHeight];
        set_param(subBlockPath, 'Position', subPos);
        if colorBlocks
            set_param(subBlockPath, 'BackgroundColor', '[0.85,0.92,1.00]');
        end
        
        ph = get_param(subBlockPath, 'PortHandles');
        
        for k = 1:numel(ph.Inport)
            pPos = get_param(ph.Inport(k), 'Position');
            pY = pPos(2);
            inName = rootInputs(k).Name;
            
            rootInName = makeUniqueBlockName(targetModel, inName);
            add_block('simulink/Sources/In1', [targetModel '/' rootInName], 'Port', num2str(k), ...
                'Position', [subX - 180, pY - 10, subX - 145, pY + 10]);
            if colorBlocks, set_param([targetModel '/' rootInName], 'BackgroundColor', globalInportColor); end
            add_line(targetModel, [rootInName '/1'], sprintf('%s/%d', subsystemName, k), 'autorouting', 'off');
        end
        
        for k = 1:numel(ph.Outport)
            pPos = get_param(ph.Outport(k), 'Position');
            pY = pPos(2);
            outName = result.RootOutputs(k).Name;
            
            rootOutName = makeUniqueBlockName(targetModel, outName);
            add_block('simulink/Sinks/Out1', [targetModel '/' rootOutName], 'Port', num2str(k), ...
                'Position', [subX + subWidth + 145, pY - 10, subX + subWidth + 180, pY + 10]);
            if colorBlocks, set_param([targetModel '/' rootOutName], 'BackgroundColor', globalOutportColor); end
            add_line(targetModel, sprintf('%s/%d', subsystemName, k), [rootOutName '/1'], 'autorouting', 'off');
        end
    end

    if options.ForceInheritedSampleTimes
        targetChanges = collectSampleTimeChanges(targetModel);
        for cIdx = 1:numel(targetChanges)
            try
                set_param(targetChanges{cIdx}.BlockPath, 'SampleTime', '-1');
            catch
            end
        end
    end

    progressFcn(0.98, 'Updating diagram...');
    try 
        set_param(targetModel, 'SimulationCommand', 'update'); 
    catch updateErr
        result.Warnings{end + 1} = sprintf('Final diagram update warning: %s', ...
            errorChainText(updateErr));
    end

    if cancelFcn()
        close_system(targetModel, 0); parentCreated = false; result.Cancelled = true;
        if ~isempty(result.BackupFile) && ~isfile(targetModelFile)
            try movefile(result.BackupFile, targetModelFile); catch, end
        end
        if options.CloseReferencedModels, closeLoadedModels(loadedByUs); end
        return;
    end

    progressFcn(0.99, 'Saving parent model...');
    
    try
        save_system(targetModel, targetModelFile, 'SaveDirtyReferencedModels', 'off');
    catch
        save_system(targetModel, targetModelFile);
    end
    
    strayCacheFile = fullfile(pwd, [targetModel '.slxc']);
    destCacheFolder = fileparts(targetModelFile);
    if isempty(destCacheFolder), destCacheFolder = pwd; end
    
    isSameDir = false;
    try
        sInfo = dir(pwd); dInfo = dir(destCacheFolder);
        isSameDir = ~isempty(sInfo) && ~isempty(dInfo) && strcmp(sInfo(1).folder, dInfo(1).folder);
    catch
        isSameDir = strcmpi(pwd, destCacheFolder);
    end
    
    if isfile(strayCacheFile) && ~isSameDir
        try movefile(strayCacheFile, fullfile(destCacheFolder, [targetModel '.slxc'])); catch, end
    end
    open_system(targetModel);

    if options.CloseReferencedModels, closeLoadedModels(loadedByUs); end
    
    result.Success = true;
    progressFcn(1, 'Done.');

catch buildError
    if parentCreated && bdIsLoaded(targetModel), close_system(targetModel, 0); end
    if ~isempty(result.BackupFile) && ~isfile(targetModelFile)
        try movefile(result.BackupFile, targetModelFile); catch, end
    end
    closeLoadedModels(loadedByUs);
    rethrow(buildError);
end
end

% =========================================================================
%  Local functions
% =========================================================================
function changes = collectSampleTimeChanges(sys)
% collectSampleTimeChanges Scans a system and returns a cell array of pending
% sample-time changes for Inports, Outports, and UnitDelays whose current
% SampleTime is NOT already '-1'.
    changes = {};
    
    if ~bdIsLoaded(sys)
        try
            load_system(sys);
        catch
            return;
        end
    end
    
    try
        if strcmp(get_param(sys, 'Lock'), 'on')
            set_param(sys, 'Lock', 'off');
        end
    catch
    end
    
    blockTypes = {'Inport', 'Outport', 'UnitDelay'};
    for bIdx = 1:numel(blockTypes)
        btype = blockTypes{bIdx};
        try
            blocks = find_system(sys, 'MatchFilter', @Simulink.match.allVariants, 'BlockType', btype);
        catch
            blocks = {};
        end
        
        for idx = 1:numel(blocks)
            blkPath = blocks{idx};
            try
                oldValue = strtrim(char(get_param(blkPath, 'SampleTime')));
            catch
                continue;
            end
            
            if strcmp(oldValue, '-1')
                continue;
            end
            
            changes{end + 1, 1} = struct( ...
                'ModelName', sys, ...
                'BlockPath', blkPath, ...
                'BlockType', btype, ...
                'OldValue',  oldValue); %#ok<AGROW>
        end
    end
end

function [val, ok] = readConfigParamSafe(modelName, paramName)
    val = '';
    ok = false;
    try
        val = char(get_param(modelName, paramName));
        ok = true;
        return;
    catch
    end
    try
        cs = getActiveConfigSet(modelName);
        if isa(cs, 'Simulink.ConfigSetRef')
            cs = cs.getRefConfigSet();
        end
        val = char(get_param(cs, paramName));
        ok = true;
        return;
    catch
    end
    try
        cs = getActiveConfigSet(modelName);
        if isa(cs, 'Simulink.ConfigSetRef')
            cs = cs.getRefConfigSet();
        end
        components = cs.getComponents();
        for cIdx = 1:numel(components)
            try
                val = char(get_param(components{cIdx}, paramName));
                ok = true;
                return;
            catch
            end
        end
    catch
    end
    ok = false;
    val = '';
end

function available = discoverModelFiles(modelsFolder)
    slxFiles = dir(fullfile(modelsFolder, '**', '*.slx'));
    mdlFiles = dir(fullfile(modelsFolder, '**', '*.mdl'));
    files = [slxFiles; mdlFiles];
    files = files(~[files.isdir]);
    
    keep = true(numel(files), 1);
    for fIdx = 1:numel(files)
        folderPath = files(fIdx).folder;
        if contains(folderPath, [filesep 'slprj']) || ...
           contains(folderPath, [filesep '.']) || ...
           contains(folderPath, [filesep 'backup'])
            keep(fIdx) = false;
        end
    end
    files = files(keep);

    fileMap = containers.Map('KeyType', 'char', 'ValueType', 'char');
    for fIdx = 1:numel(files)
        [~, bName] = fileparts(files(fIdx).name);
        key = lower(bName);
        filePath = fullfile(files(fIdx).folder, files(fIdx).name);
        
        if ~isKey(fileMap, key)
            fileMap(key) = filePath;
        else
            if strcmpi(files(fIdx).folder, modelsFolder)
                fileMap(key) = filePath;
            end
        end
    end

    allKeys = fileMap.keys();
    available.names = cell(numel(allKeys), 1);
    available.paths = cell(numel(allKeys), 1);
    for kIdx = 1:numel(allKeys)
        k = allKeys{kIdx};
        p = fileMap(k);
        [~, origName] = fileparts(p);
        available.names{kIdx} = origName;
        available.paths{kIdx} = p;
    end
end

function [inputNames, outputNames] = getRootPortNames(modelName)
inputBlocks = find_system(char(modelName), 'SearchDepth', 1, 'FollowLinks', 'on', 'LookUnderMasks', 'all', 'BlockType', 'Inport');
outputBlocks = find_system(char(modelName), 'SearchDepth', 1, 'FollowLinks', 'on', 'LookUnderMasks', 'all', 'BlockType', 'Outport');
inputNames = orderedPortNames(inputBlocks, 'In');
outputNames = orderedPortNames(outputBlocks, 'Out');
end

function names = orderedPortNames(blocks, kind)
names = {};
if isempty(blocks), return; end
if ~iscell(blocks), blocks = num2cell(blocks); end
blocks = blocks(:);
portNumbers = zeros(numel(blocks), 1);
for blockIndex = 1:numel(blocks)
    targetBlock = blocks{blockIndex};
    portNumber = str2double(get_param(targetBlock, 'Port'));
    if isnan(portNumber), error('buildParentModelCore:BadPortNumber', 'Invalid port number.'); end
    portNumbers(blockIndex) = portNumber;
end
[~, order] = sort(portNumbers);
sortedBlocks = blocks(order);
blockNames = cell(numel(sortedBlocks), 1);
for blockIndex = 1:numel(sortedBlocks)
    bName = get_param(sortedBlocks{blockIndex}, 'Name');
    if iscell(bName), bName = bName{1}; end
    bName = char(bName);
    if isempty(strtrim(bName))
        bName = sprintf('%s%d', kind, portNumbers(order(blockIndex)));
    end
    blockNames{blockIndex} = bName;
end
names = blockNames;
end

function key = normKey(name, caseInsensitive)
if caseInsensitive, key = lower(char(name)); else, key = char(name); end
end

function closeLoadedModels(loadedByUs)
for modelIndex = 1:numel(loadedByUs)
    try if bdIsLoaded(loadedByUs{modelIndex}), close_system(loadedByUs{modelIndex}, 0); end, catch, end
end
end

function uniqueName = makeUniqueBlockName(systemName, requestedName)
requestedName = strtrim(char(requestedName));
if isempty(requestedName), requestedName = 'Block'; end
requestedName = strrep(requestedName, '/', '_');
uniqueName = requestedName;
if ~isempty(regexp(uniqueName, '_\d+$', 'once'))
    parts = regexp(uniqueName, '^(.+)_(\d+)$', 'tokens', 'once');
    stem = parts{1}; counter = str2double(parts{2});
    while blockExists([systemName '/' uniqueName])
        counter = counter + 1; uniqueName = sprintf('%s_%d', stem, counter);
    end
else
    suffix = 2;
    while blockExists([systemName '/' uniqueName])
        uniqueName = sprintf('%s_%d', requestedName, suffix); suffix = suffix + 1;
    end
end
end

function exists = blockExists(blockPath)
try get_param(blockPath, 'Handle'); exists = true; catch, exists = false; end
end

function addLineRouted(systemName, routeMode, varargin)
if strcmp(routeMode, 'smart')
    try add_line(systemName, varargin{:}, 'autorouting', 'smart'); return; catch, end
end
add_line(systemName, varargin{:}, 'autorouting', 'on');
end

function s = safeName(s)
s = char(matlab.lang.makeValidName(s, 'ReplacementStyle', 'underscore'));
s = regexprep(s, '_+', '_');
s = regexprep(s, '^_+', '');
if isempty(s), s = 'signal'; end
end

function tf = isSelfFeeding(modelOutputKeys, modelIndex, key)
tf = any(strcmp(modelOutputKeys{modelIndex}, key));
end

function options = fillDefaults(options, defaults)
if isempty(options), options = struct(); end
fields = fieldnames(defaults);
for index = 1:numel(fields)
    if ~isfield(options, fields{index}), options.(fields{index}) = defaults.(fields{index}); end
end
end

function colorString = paletteColor(index)
palette = [ ...
    0.40 0.70 0.95; 0.95 0.55 0.40; 0.95 0.80 0.30; 0.65 0.50 0.85; ...
    0.45 0.80 0.40; 0.35 0.75 0.85; 0.90 0.45 0.60; 0.40 0.80 0.65; ...
    0.55 0.60 0.90; 0.90 0.55 0.75; 0.35 0.70 0.70; 0.95 0.65 0.35; ...
    0.70 0.55 0.90; 0.90 0.55 0.70; 0.55 0.80 0.40; 0.45 0.65 0.90; ...
    0.80 0.65 0.40; 0.75 0.50 0.60; 0.40 0.75 0.75; 0.75 0.80 0.40; ...
    0.65 0.60 0.90; 0.40 0.60 0.85; 0.90 0.60 0.45; 0.40 0.80 0.60];
rgb = palette(mod(index - 1, size(palette, 1)) + 1, :);
colorString = sprintf('[%.2f,%.2f,%.2f]', rgb(1), rgb(2), rgb(3));
end

function text = errorChainText(err)
text = strtrim(char(err.message));
if isempty(text), text = '(no message)'; end
for groupIndex = 1:numel(err.cause)
    causeGroup = err.cause{groupIndex};
    for causeIndex = 1:numel(causeGroup)
        causeText = strtrim(char(causeGroup(causeIndex).message));
        if ~isempty(causeText), text = [text newline '   ' causeText]; end %#ok<AGROW>
    end
end
text = regexprep(text, '<a[^>]*>\s*([^<]*?)\s*</a>', '$1');
end