function result = buildParentModelCore(modelsFolder, selectedModels, targetModelName, options)
%BUILDPARENTMODELCORE Shared engine that generates a parent Simulink model
% containing Model Reference blocks with automated dynamic alignment.

% ---------------------------------------------------------------- Defaults
if nargin < 4 || isempty(options)
    options = struct();
end
options = fillDefaults(options, struct( ...
    'OutputFolder',          '', ...
    'Overwrite',             false, ...
    'BackupExisting',        true, ...
    'CaseInsensitiveMatch',  true, ...
    'ConfigParameters',      {{'UseDivisionForNetSlopeComputation'}}, ...
    'CloseReferencedModels', true, ...
    'WrapInSubsystem',       false, ...
    'TidyLayout',            true, ...
    'ConnectionMethod',      'lines', ...
    'Layout',                'vertical', ...
    'ColorBlocks',           false, ...
    'AutoDelayFeedback',     false, ...
    'BlockSpacing',          100, ...
    'FromModelGap',          [], ...
    'ModelGotoGap',          [], ...
    'FromToDelayGap',        [], ...
    'ModelToModelGap',       [], ...
    'PreviewOnly',           false, ...
    'ProgressFcn',           @(~, ~) [], ...
    'CancelRequestedFcn',    @false));

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
    end
catch loadError
    closeLoadedModels(loadedByUs);
    error('buildParentModelCore:ModelLoadFailed', ...
        'Could not load model %s.\n\nDetails:\n%s', modelPaths{modelIndex}, errorChainText(loadError));
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
        readable = true;
        for modelIndex = 1:numModels
            try
                values{modelIndex} = char(get_param(modelNames{modelIndex}, parameter));
            catch readError
                configProblems{end + 1} = sprintf('Could not read "%s" from model "%s": %s', ...
                    parameter, modelNames{modelIndex}, readError.message); %#ok<AGROW>
                readable = false;
                break;
            end
        end
        if ~readable, continue; end

        allMatch = true;
        for modelIndex = 2:numModels
            if ~strcmpi(values{modelIndex}, values{1})
                allMatch = false;
                configProblems{end + 1} = sprintf('"%s" differs: %s = %s vs %s = %s', ...
                    parameter, modelNames{1}, values{1}, modelNames{modelIndex}, values{modelIndex}); %#ok<AGROW>
            end
        end
        if allMatch
            configParamNames{paramIndex} = parameter;
            configParamValues{paramIndex} = values{1};
        end
    end

    if ~isempty(configProblems)
        error('buildParentModelCore:ConfigMismatch', ...
            'Configuration mismatch:\n%s', strjoin(configProblems, newline));
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

    result.Models = struct('Name', modelNames, 'Path', modelPaths, ...
        'InputNames', cell(numModels, 1), 'OutputNames', cell(numModels, 1));
    for modelIndex = 1:numModels
        result.Models(modelIndex).InputNames = modelInfo(modelIndex).InputNames;
        result.Models(modelIndex).OutputNames = modelInfo(modelIndex).OutputNames;
    end

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
    if ~isempty(flatOutputs)
        flatKeys = cellfun(@(s) normKey(s, caseInsensitive), flatOutputs, 'UniformOutput', false);
        connectionSourceKeys = cellfun(@(s) normKey(s, caseInsensitive), {internalConnections.SrcPort}, 'UniformOutput', false);
        [uniqueKeys, ~, keyGroups] = unique(flatKeys);
        for keyIndex = 1:numel(uniqueKeys)
            thisGroup = find(keyGroups == keyIndex);
            ownerIndexes = unique(flatOwners(thisGroup));
            if numel(ownerIndexes) <= 1, continue; end
            if ~any(strcmp(connectionSourceKeys, uniqueKeys{keyIndex})), continue; end
            ownerNames = modelNames(ownerIndexes);
            result.Warnings{end + 1} = sprintf('Output "%s" exists in multiple models (%s). Only "%s" feeds internal connections.', ...
                flatOutputs{thisGroup(1)}, strjoin(ownerNames(:), ', '), ownerNames{1}); %#ok<AGROW>
        end
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
        set_param(targetModel, result.ConfigParamNames{paramIndex}, result.ConfigParamValues{paramIndex});
    end
    set_param(targetModel, 'SolverType', 'Fixed-step', 'Solver', 'FixedStepDiscrete');

    if strcmp(connectionMethod, 'fromgoto')
        % ============================================================
        % FROM/GOTO MODE
        % ============================================================
        progressFcn(0.65, 'Adding Model Reference blocks (From/Goto style)...');

        signalKeys = {}; signalNames = {}; signalModels = {};
        inputKeys = {}; modelOutputKeys = cell(numModels, 1);
        modelInputKeys = cell(numModels, 1);
        
        for modelIndex = 1:numModels
            outKeys = cell(numel(modelInfo(modelIndex).OutputNames), 1);
            for outputIndex = 1:numel(modelInfo(modelIndex).OutputNames)
                sig = modelInfo(modelIndex).OutputNames{outputIndex};
                key = normKey(sig, caseInsensitive);
                outKeys{outputIndex} = key;
                signalKeys{end + 1, 1} = key;   %#ok<AGROW>
                signalNames{end + 1, 1} = sig;  %#ok<AGROW>
                signalModels{end + 1, 1} = modelInfo(modelIndex).Name;  %#ok<AGROW>
            end
            modelOutputKeys{modelIndex} = outKeys;
            
            inKeys = cell(numel(modelInfo(modelIndex).InputNames), 1);
            for inputIndex = 1:numel(modelInfo(modelIndex).InputNames)
                sig = modelInfo(modelIndex).InputNames{inputIndex};
                key = normKey(sig, caseInsensitive);
                inKeys{inputIndex} = key;
                inputKeys{end + 1, 1} = key;    %#ok<AGROW>
                signalKeys{end + 1, 1} = key;   %#ok<AGROW>
                signalNames{end + 1, 1} = sig;  %#ok<AGROW>
                signalModels{end + 1, 1} = modelInfo(modelIndex).Name;  %#ok<AGROW>
            end
            modelInputKeys{modelIndex} = inKeys;
        end

        tagOf = containers.Map('KeyType', 'char', 'ValueType', 'char');
        usedTags = {};
        for signalIndex = 1:numel(signalKeys)
            key = signalKeys{signalIndex};
            if ~isKey(tagOf, key)
                baseTag = safeName(signalNames{signalIndex});
                tag = baseTag;
                suffix = 2;
                while any(strcmp(usedTags, tag))
                    if suffix == 2
                        modelTag = safeName(signalModels{signalIndex});
                        if ~isempty(modelTag) && ~any(strcmp(usedTags, [baseTag '_' modelTag]))
                            tag = [baseTag '_' modelTag];
                            break;
                        end
                    end
                    tag = sprintf('%s_%d', baseTag, suffix);
                    suffix = suffix + 1;
                end
                tagOf(key) = tag;
                usedTags{end + 1} = tag; %#ok<AGROW>
            end
        end

        maxProducerOrder = containers.Map('KeyType', 'char', 'ValueType', 'double');
        firstProducerOrder = containers.Map('KeyType', 'char', 'ValueType', 'double');
        for modelIndex = 1:numModels
            for outputIndex = 1:numel(modelOutputKeys{modelIndex})
                key = modelOutputKeys{modelIndex}{outputIndex};
                if ~isKey(firstProducerOrder, key), firstProducerOrder(key) = modelIndex; end
                if isKey(maxProducerOrder, key), maxProducerOrder(key) = max(maxProducerOrder(key), modelIndex);
                else, maxProducerOrder(key) = modelIndex; end
            end
        end

        minConsumerOrder = containers.Map('KeyType', 'char', 'ValueType', 'double');
        for modelIndex = 1:numModels
            for inputIndex = 1:numel(modelInputKeys{modelIndex})
                key = modelInputKeys{modelIndex}{inputIndex};
                if isKey(minConsumerOrder, key), minConsumerOrder(key) = min(minConsumerOrder(key), modelIndex);
                else, minConsumerOrder(key) = modelIndex; end
            end
        end

        % Collect unique output key list for global ports and duplicate warnings
        allOutputKeys = {};
        for modelIndex = 1:numModels
            allOutputKeys = [allOutputKeys; modelOutputKeys{modelIndex}]; %#ok<AGROW>
        end
        uniqueOutputKeyList = unique(allOutputKeys);

        for keyIndex = 1:numel(uniqueOutputKeyList)
            key = uniqueOutputKeyList{keyIndex};
            producerCount = 0;
            for modelIndex = 1:numModels
                if any(strcmp(modelOutputKeys{modelIndex}, key))
                    producerCount = producerCount + 1;
                end
            end
            if producerCount > 1
                result.Warnings{end + 1} = sprintf( ...
                    ['Signal "%s" is produced by %d models. With From/Goto ', ...
                     'routing every signal name must be unique - rename the ', ...
                     'duplicate output ports.'], tagOf(key), producerCount); %#ok<AGROW>
            end
        end

        % Dynamic width ensures tag names are 100% readable without truncation (...)
        longestTagLength = 6;
        for tagIndex = 1:numel(usedTags)
            longestTagLength = max(longestTagLength, numel(usedTags{tagIndex}));
        end
        commonFromGotoWidth = max(100, ceil(longestTagLength * 8.5) + 30);
        
        modelWidth = 260;
        uniformModelH = 140;
        for m = 1:numModels
            nP = max([numel(modelInfo(m).InputNames), numel(modelInfo(m).OutputNames), 1]);
            uniformModelH = max(uniformModelH, (nP + 1) * 36); % 36px clean port pitch
        end
        
        fromGap = fromModelGap;
        gotoGap = modelGotoGap;
        delayGap = fromToDelayGap;
        
        % DYNAMIC MODEL-TO-MODEL SPACING MATH (GUARANTEES ZERO OVERLAPS)
        tagClearance = 120; % Generous 120pt air gap between model Goto and next model From
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
        
        % FAR-LEFT CLEARANCE: Root Inport (50) + Width (35) + Gap (40) + Root Goto + 120pt Air Gap
        maxRootGotoW = 100;
        for sIdx = 1:numel(usedTags)
            maxRootGotoW = max(maxRootGotoW, ceil(numel(usedTags{sIdx}) * 8.5) + 30);
        end
        rootClearance = 120;
        modelBaseX = 50 + 35 + 40 + maxRootGotoW + rootClearance + commonFromGotoWidth + (delayGap + 40) + fromGap;
        
        globalInportColor = '[0.65,0.90,0.65]';
        globalOutportColor = '[0.95,0.70,0.45]';

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
            blockName = makeUniqueBlockName(targetModel, modelInfo(modelIndex).Name);
            modelBlockNames{modelIndex} = blockName;
            modelInfo(modelIndex).BlockPos = [blockX, blockY, blockX + modelWidth, blockY + uniformModelH];
            
            add_block('simulink/Ports & Subsystems/Model', [targetModel '/' blockName], ...
                'ModelName', modelInfo(modelIndex).Name, 'Position', modelInfo(modelIndex).BlockPos);
            if colorBlocks
                set_param([targetModel '/' blockName], 'BackgroundColor', paletteColor(modelIndex));
            end
            rightMostEdge = max(rightMostEdge, blockX + modelWidth + gotoGap + commonFromGotoWidth);
        end

        set_param(targetModel, 'SimulationCommand', 'update');

        progressFcn(0.75, 'Reading the model ports...');
        for modelIndex = 1:numModels
            portHandles = get_param([targetModel '/' modelBlockNames{modelIndex}], 'PortHandles');
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
                key = normKey(sig, caseInsensitive);
                tag = tagOf(key);
                signalY = modelInfo(modelIndex).InputPortYs(inputIndex);

                fromCounter = 1;
                if isKey(fromCountByTag, tag), fromCounter = fromCountByTag(tag) + 1; end
                fromCountByTag(tag) = fromCounter;
                fromName = makeUniqueBlockName(targetModel, sprintf('%s_From_%d', tag, fromCounter));
                
                selfFeed = isSelfFeeding(modelOutputKeys, modelIndex, key) && ...
                    isKey(firstProducerOrder, key) && firstProducerOrder(key) == modelIndex && ...
                    isKey(maxProducerOrder, key) && maxProducerOrder(key) == modelIndex;
                inputIsFeedback = autoDelayFeedback && ((isKey(maxProducerOrder, key) && maxProducerOrder(key) > modelIndex) || selfFeed);
                
                if inputIsFeedback
                    fromRight = blockPos(1) - (fromModelGap + fromToDelayGap + 40);
                else
                    fromRight = blockPos(1) - fromGap;
                end
                fromLeft = fromRight - commonFromGotoWidth;
                
                add_block('simulink/Signal Routing/From', [targetModel '/' fromName], 'GotoTag', tag, ...
                    'Position', [fromLeft, signalY - 10, fromRight, signalY + 10]);
                if colorBlocks && isKey(firstProducerOrder, key)
                    set_param([targetModel '/' fromName], 'BackgroundColor', paletteColor(firstProducerOrder(key)));
                end

                if inputIsFeedback
                    delayName = makeUniqueBlockName(targetModel, sprintf('UnitDelay_%d', autoDelayCount + 1));
                    delayLeft = fromRight + fromToDelayGap;
                    add_block('built-in/UnitDelay', [targetModel '/' delayName], ...
                        'Position', [delayLeft, signalY - 10, delayLeft + 40, signalY + 10]);
                    if colorBlocks && isKey(firstProducerOrder, key)
                        set_param([targetModel '/' delayName], 'BackgroundColor', paletteColor(firstProducerOrder(key)));
                    end
                    add_line(targetModel, [fromName '/1'], [delayName '/1'], 'autorouting', 'off');
                    add_line(targetModel, [delayName '/1'], sprintf('%s/%d', modelBlockNames{modelIndex}, inputIndex), 'autorouting', 'off');
                    autoDelayCount = autoDelayCount + 1;
                else
                    add_line(targetModel, [fromName '/1'], sprintf('%s/%d', modelBlockNames{modelIndex}, inputIndex), 'autorouting', 'off');
                end
            end

            for outputIndex = 1:numel(modelInfo(modelIndex).OutputNames)
                sig = modelInfo(modelIndex).OutputNames{outputIndex};
                key = normKey(sig, caseInsensitive);
                tag = tagOf(key);
                signalY = modelInfo(modelIndex).OutputPortYs(outputIndex);

                gotoLeft = blockPos(3) + gotoGap;
                gotoCounter = 1;
                if isKey(gotoCountByTag, tag), gotoCounter = gotoCountByTag(tag) + 1; end
                gotoCountByTag(tag) = gotoCounter;
                gotoName = makeUniqueBlockName(targetModel, sprintf('%s_Goto_%d', tag, gotoCounter));
                
                add_block('simulink/Signal Routing/Goto', [targetModel '/' gotoName], 'GotoTag', tag, ...
                    'Position', [gotoLeft, signalY - 10, gotoLeft + commonFromGotoWidth, signalY + 10]);
                if colorBlocks
                    set_param([targetModel '/' gotoName], 'BackgroundColor', paletteColor(modelIndex));
                end
                add_line(targetModel, sprintf('%s/%d', modelBlockNames{modelIndex}, outputIndex), [gotoName '/1'], 'autorouting', 'off');
            end
        end

        progressFcn(0.88, 'Adding global inputs and outputs...');
        uniqueInputKeyList = unique(inputKeys);
        globalInputKeyList = setdiff(uniqueInputKeyList, uniqueOutputKeyList, 'stable');

        for g = 1:numel(globalInputKeyList)
            key = globalInputKeyList{g};
            tag = tagOf(key);
            signalY = 50 + g * 36;
            inBlockName = makeUniqueBlockName(targetModel, tag);
            
            add_block('simulink/Sources/In1', [targetModel '/' inBlockName], 'Port', num2str(g), ...
                'Position', [50, signalY - 10, 85, signalY + 10]);
            if colorBlocks, set_param([targetModel '/' inBlockName], 'BackgroundColor', globalInportColor); end
            
            gotoBlockName = makeUniqueBlockName(targetModel, ['Goto_' tag]);
            globalGotoLeft = 85 + blockSpacing;
            
            add_block('simulink/Signal Routing/Goto', [targetModel '/' gotoBlockName], 'GotoTag', tag, ...
                'Position', [globalGotoLeft, signalY - 10, globalGotoLeft + commonFromGotoWidth, signalY + 10]);
            
            add_line(targetModel, [inBlockName '/1'], [gotoBlockName '/1'], 'autorouting', 'off');
        end

        globalFromX = rightMostEdge + max(300, 2 * blockSpacing + 100);
        globalOutX = globalFromX + commonFromGotoWidth + blockSpacing;
        
        uniqueRootOutputs = struct('Name', {}, 'SourceModel', {}, 'SourcePort', {}, 'SourceModelIndex', {}, 'SourcePortIndex', {});
        for g = 1:numel(uniqueOutputKeyList)
            key = uniqueOutputKeyList{g};
            tag = tagOf(key);
            signalY = 50 + g * 36;
            fromBlockName = makeUniqueBlockName(targetModel, ['From_' tag]);
            
            add_block('simulink/Signal Routing/From', [targetModel '/' fromBlockName], 'GotoTag', tag, ...
                'Position', [globalFromX, signalY - 10, globalFromX + commonFromGotoWidth, signalY + 10]);
            if colorBlocks && isKey(firstProducerOrder, key)
                set_param([targetModel '/' fromBlockName], 'BackgroundColor', paletteColor(firstProducerOrder(key)));
            end
            
            outBlockName = makeUniqueBlockName(targetModel, tag);
            add_block('simulink/Sinks/Out1', [targetModel '/' outBlockName], 'Port', num2str(g), ...
                'Position', [globalOutX, signalY - 10, globalOutX + 35, signalY + 10]);
            if colorBlocks, set_param([targetModel '/' outBlockName], 'BackgroundColor', globalOutportColor); end
            add_line(targetModel, [fromBlockName '/1'], [outBlockName '/1'], 'autorouting', 'off');

            prodIndex = 1;
            if isKey(firstProducerOrder, key), prodIndex = firstProducerOrder(key); end
            portIdx = find(strcmp(modelOutputKeys{prodIndex}, key), 1);
            if isempty(portIdx), portIdx = 1; end
            uniqueRootOutputs(g) = struct('Name', tag, 'SourceModel', modelInfo(prodIndex).Name, ...
                'SourcePort', modelInfo(prodIndex).OutputNames{portIdx}, 'SourceModelIndex', prodIndex, 'SourcePortIndex', portIdx);
        end
        result.RootOutputs = uniqueRootOutputs;
        result.Counts.RootOutputs = numel(uniqueRootOutputs);
        result.Counts.Internal = numel(internalConnections);
        result.Counts.RootInputs = numel(globalInputKeyList);

    else
        % ============================================================
        % DIRECT LINES MODE
        % ============================================================
        progressFcn(0.65, 'Adding Model Reference blocks...');
        modelBlockNames = cell(numModels, 1);
        modelTopBottom = zeros(numModels, 2);
        currentModelY = 80; currentModelX = 450;
        
        for modelIndex = 1:numModels
            maxPorts = max([numel(modelInfo(modelIndex).InputNames), numel(modelInfo(modelIndex).OutputNames), 1]);
            cH = max(160, maxPorts * 35);
            blockName = makeUniqueBlockName(targetModel, modelInfo(modelIndex).Name);
            modelBlockNames{modelIndex} = blockName;

            if strcmp(layoutStyle, 'horizontal')
                bPos = [currentModelX, currentModelY, currentModelX + 240, currentModelY + cH];
                currentModelX = currentModelX + 240 + 100;
            else
                bPos = [450, currentModelY, 450 + 240, currentModelY + cH];
                currentModelY = currentModelY + cH + 100;
            end

            add_block('simulink/Ports & Subsystems/Model', [targetModel '/' blockName], ...
                'ModelName', modelInfo(modelIndex).Name, 'Position', bPos);
            if colorBlocks, set_param([targetModel '/' blockName], 'BackgroundColor', paletteColor(modelIndex)); end
            modelTopBottom(modelIndex, :) = [bPos(2), bPos(4)];
        end

        outportX = currentModelX - 100 + 300;
        set_param(targetModel, 'SimulationCommand', 'update');

        for modelIndex = 1:numModels
            pH = get_param([targetModel '/' modelBlockNames{modelIndex}], 'PortHandles');
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
                srcPos = get_param([targetModel '/' modelBlockNames{conn.SrcModelIndex}], 'Position');
                dstPos = get_param(dstH, 'Position');
                dLeft = round(dstPos(1)) - 40 - blockSpacing;
                if dLeft < srcPos(3) + blockSpacing, dLeft = round((srcPos(3) + dstPos(1)) / 2) - 20; end
                dY = round(dstPos(2));
                dName = makeUniqueBlockName(targetModel, sprintf('UnitDelay_%d', autoDelayCount + 1));
                add_block('built-in/UnitDelay', [targetModel '/' dName], 'Position', [dLeft, dY - 10, dLeft + 40, dY + 10]);
                dPorts = get_param([targetModel '/' dName], 'PortHandles');
                addLineRouted(targetModel, routeMode, srcH, dPorts.Inport(1));
                addLineRouted(targetModel, routeMode, dPorts.Outport(1), dstH);
                autoDelayCount = autoDelayCount + 1;
            else
                addLineRouted(targetModel, routeMode, srcH, dstH);
            end
        end

        if ~isempty(rootInputs)
            order = 1:numel(rootInputs); spacedYs = (1:numel(rootInputs))' * 45 + 50;
            for pos = 1:numel(order)
                iIdx = order(pos);
                iName = makeUniqueBlockName(targetModel, rootInputs(iIdx).Name);
                add_block('simulink/Sources/In1', [targetModel '/' iName], 'Port', num2str(pos), ...
                    'Position', [50, round(spacedYs(pos)), 50 + 35, round(spacedYs(pos)) + 20]);
                rH = get_param([targetModel '/' iName], 'PortHandles'); rH = rH.Outport;
                for d = 1:numel(rootInputs(iIdx).DestinationModelIndexes)
                    mIdx = rootInputs(iIdx).DestinationModelIndexes(d);
                    pIdx = rootInputs(iIdx).DestinationPortIndexes(d);
                    addLineRouted(targetModel, routeMode, rH, modelInfo(mIdx).InputHandles(pIdx));
                end
            end
        end

        if ~isempty(rootOutputs)
            order = 1:numel(rootOutputs); spacedYs = (1:numel(rootOutputs))' * 45 + 50;
            for pos = 1:numel(order)
                oIdx = order(pos);
                oName = makeUniqueBlockName(targetModel, rootOutputs(oIdx).Name);
                add_block('simulink/Sinks/Out1', [targetModel '/' oName], 'Port', num2str(pos), ...
                    'Position', [outportX, round(spacedYs(pos)), outportX + 35, round(spacedYs(pos)) + 20]);
                sPort = sprintf('%s/%d', modelBlockNames{rootOutputs(oIdx).SourceModelIndex}, rootOutputs(oIdx).SourcePortIndex);
                dPort = sprintf('%s/1', oName);
                addLineRouted(targetModel, routeMode, sPort, dPort);
            end
        end
    end

    progressFcn(0.97, 'Updating diagram...');
    try set_param(targetModel, 'SimulationCommand', 'update'); catch, end

    if cancelFcn()
        close_system(targetModel, 0); parentCreated = false; result.Cancelled = true;
        if ~isempty(result.BackupFile) && ~isfile(targetModelFile)
            try movefile(result.BackupFile, targetModelFile); catch, end
        end
        if options.CloseReferencedModels, closeLoadedModels(loadedByUs); end
        return;
    end

    % ---------------------------------------------------- Wrapper Subsystem
    if options.WrapInSubsystem
        progressFcn(0.98, 'Wrapping contents in a subsystem...');
        try
            subsystemName = matlab.lang.makeValidName([targetModel '_Core']);
            
            % Find all top-level blocks in the model
            allRootBlocks = find_system(targetModel, 'SearchDepth', 1, 'Type', 'block');
            if ~iscell(allRootBlocks), allRootBlocks = num2cell(allRootBlocks); end
            
            % Selectively filter out top-level parent ports from selection
            wrapHandles = [];
            for idx = 1:numel(allRootBlocks)
                blk = allRootBlocks{idx};
                if isequal(blk, targetModel) || isequal(blk, get_param(targetModel, 'Handle'))
                    continue;
                end
                bType = get_param(blk, 'BlockType');
                if ~strcmp(bType, 'Inport') && ~strcmp(bType, 'Outport')
                    wrapHandles(end + 1, 1) = get_param(blk, 'Handle'); %#ok<AGROW>
                end
            end
            
            if ~isempty(wrapHandles)
                subsystemHandle = Simulink.BlockDiagram.createSubsystem(wrapHandles, 'Name', subsystemName);
                result.SubsystemName = subsystemName;
                
                % Compute port handles
                ph = get_param(subsystemHandle, 'PortHandles');
                nSubIn = numel(ph.Inport);
                nSubOut = numel(ph.Outport);
                
                % Calculate clean dimensions proportional to the port count
                subHeight = max(120, max(nSubIn, nSubOut) * 35 + 20);
                subWidth = 240;
                subX = 350;
                subY = 150;
                subPos = [subX, subY, subX + subWidth, subY + subHeight];
                set_param(subsystemHandle, 'Position', subPos);
                
                % Align root level Inport blocks nicely in a column
                rootInports = find_system(targetModel, 'SearchDepth', 1, 'BlockType', 'Inport');
                if ~iscell(rootInports), rootInports = num2cell(rootInports); end
                for k = 1:numel(rootInports)
                    portNum = str2double(get_param(rootInports{k}, 'Port'));
                    if isnan(portNum), portNum = k; end
                    
                    if portNum <= nSubIn
                        py = subPos(2) + round((subPos(4) - subPos(2)) * (portNum / (nSubIn + 1)));
                        ip = [subPos(1) - fromModelGap - 100, py - 10, subPos(1) - fromModelGap - 65, py + 10];
                        set_param(rootInports{k}, 'Position', ip);
                    end
                end
                
                % Align root level Outport blocks nicely in a column
                rootOutports = find_system(targetModel, 'SearchDepth', 1, 'BlockType', 'Outport');
                if ~iscell(rootOutports), rootOutports = num2cell(rootOutports); end
                for k = 1:numel(rootOutports)
                    portNum = str2double(get_param(rootOutports{k}, 'Port'));
                    if isnan(portNum), portNum = k; end
                    
                    if portNum <= nSubOut
                        py = subPos(2) + round((subPos(4) - subPos(2)) * (portNum / (nSubOut + 1)));
                        op = [subPos(3) + modelGotoGap + 65, py - 10, subPos(3) + modelGotoGap + 100, py + 10];
                        set_param(rootOutports{k}, 'Position', op);
                    end
                end
            end
        catch wrapErr
            result.Warnings{end + 1} = ['Wrapping in subsystem failed: ' wrapErr.message];
        end
    end

    progressFcn(0.99, 'Saving...');
    save_system(targetModel, targetModelFile);
    
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

    if options.CloseReferencedModels
        closeLoadedModels(loadedByUs);
    end
    
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
function available = discoverModelFiles(modelsFolder)
slxFiles = dir(fullfile(modelsFolder, '**', '*.slx'));
mdlFiles = dir(fullfile(modelsFolder, '**', '*.mdl'));
files = [slxFiles; mdlFiles];
available.names = cell(numel(files), 1);
available.paths = cell(numel(files), 1);
for fileIndex = 1:numel(files)
    [~, discoveredName] = fileparts(files(fileIndex).name);
    available.names{fileIndex} = discoveredName;
    available.paths{fileIndex} = fullfile(files(fileIndex).folder, files(fileIndex).name);
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