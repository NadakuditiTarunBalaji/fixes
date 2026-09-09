function result = buildParentModelCore(modelsFolder, selectedModels, targetModelName, options)
%BUILDPARENTMODELCORE Shared engine that generates a parent Simulink model
% containing Model Reference blocks.
%
%   result = buildParentModelCore(modelsFolder, selectedModels, targetModelName, options)
%
% This engine is used by BOTH the command-line script
% (createReferenceModels.m) and the app (teamtools.m). All Simulink API
% calls use char values for maximum MATLAB version compatibility.
%
% INPUTS
%   modelsFolder    Folder searched recursively for .slx/.mdl files.
%   selectedModels  Referenced-model names, in the desired vertical order.
%                   (string array, cellstr, or single char/string.)
%   targetModelName Name for the generated parent model (made valid).
%   options         Optional struct (all fields optional):
%     OutputFolder          where to save the .slx (default: modelsFolder)
%     Overwrite             allow overwriting an existing file (default false)
%     BackupExisting        create a .bak of an overwritten file (default true)
%     CaseInsensitiveMatch  match port names case-insensitively (default true)
%     ConfigParameters      cellstr of config params that must match across
%                           all referenced models
%                           (default {'UseDivisionForNetSlopeComputation'})
%     CloseReferencedModels close models this engine loaded (default true)
%     WrapInSubsystem       wrap all generated content in one subsystem
%     ConnectionMethod      'lines' (direct connections) or 'fromgoto'
%                           (signals routed through Goto/From tags)
%     Layout                'vertical' (stacked) or 'horizontal'
%     ColorBlocks           give each model its own background color
%     AutoDelayFeedback     insert Unit Delays on feedback signals
%     BlockSpacing          clear distance in points between newly
%                           placed blocks (minimum 55, default 100)
%     FromModelGap          gap From block -> model ([] = BlockSpacing)
%     ModelGotoGap          gap model -> Goto block ([] = BlockSpacing)
%     FromToDelayGap        gap From block -> Unit Delay ([] = same)
%     ModelToModelGap       space between neighbouring models ([] =
%                           automatic; vertical default was 100)
%                           (produced by a model later in the list)
%                           (default false)
%     TidyLayout            smart line routing + aligned ports (default true)
%     PreviewOnly           plan and check only, build nothing (default false)
%     ProgressFcn           function handle @(fraction, message)
%     CancelRequestedFcn    function handle returning logical
%
% RESULT (struct)
%   .Success .Cancelled .PreviewOnly .TargetModel .OutputFile
%   .Models (Name, Path, InputNames, OutputNames)
%   .InternalConnections (SrcModel, SrcPort, DstModel, DstPort, + indexes)
%   .RootInputs (Name, DestinationModels, DestinationPorts, + indexes)
%   .RootOutputs (Name, SourceModel, SourcePort, + indexes)
%   .ConfigParamNames .ConfigParamValues .Warnings
%   .Counts (Internal, RootInputs, RootOutputs)
%   .SubsystemName (char, '' when not wrapped) .BackupFile (char or '')
%
% On failure the engine closes any half-built parent model WITHOUT saving
% and rethrows the error with a readable message.

% ---------------------------------------------------------------- defaults
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
% user-tunable gaps ([] = derive from BlockSpacing as before)
fromModelGap = blockSpacing;
if ~isempty(options.FromModelGap)
    fromModelGap = max(20, round(double(options.FromModelGap)));
end
modelGotoGap = blockSpacing;
if ~isempty(options.ModelGotoGap)
    modelGotoGap = max(20, round(double(options.ModelGotoGap)));
end
fromToDelayGap = blockSpacing;
if ~isempty(options.FromToDelayGap)
    fromToDelayGap = max(10, round(double(options.FromToDelayGap)));
end

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

% ------------------------------------------------------------ validate in
modelsFolder = char(modelsFolder);
if ~isfolder(modelsFolder)
    error('buildParentModelCore:InvalidFolder', ...
        'The models folder does not exist: %s', modelsFolder);
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
    error('buildParentModelCore:NoModelsSelected', ...
        'Select at least one referenced model.');
end
numModels = numel(selectedModels);

targetModel = char(targetModelName);
targetModel = strtrim(targetModel);
targetModel = regexprep(targetModel, '\.(slx|mdl)$', '', 'ignorecase');
if isempty(targetModel)
    targetModel = 'GeneratedReferenceModel';
end
validTarget = matlab.lang.makeValidName(targetModel);
targetModel = validTarget;
result.TargetModel = targetModel;

if any(strcmpi(selectedModels, targetModel))
    error('buildParentModelCore:NameClash', ...
        ['The generated model name "%s" must differ from the ', ...
         'referenced-model names.'], targetModel);
end

if isempty(options.OutputFolder)
    outputFolder = modelsFolder;
else
    outputFolder = char(options.OutputFolder);
end
if ~isfolder(outputFolder)
    error('buildParentModelCore:InvalidOutputFolder', ...
        'The output folder does not exist: %s', outputFolder);
end

targetModelFile = fullfile(outputFolder, [targetModel '.slx']);
result.OutputFile = targetModelFile;

if ~result.PreviewOnly && isfile(targetModelFile) && ~options.Overwrite
    error('buildParentModelCore:FileExists', ...
        ['The model file already exists:\n%s\n\nOverwrite it (or choose ', ...
         'a different name).'], targetModelFile);
end

% --------------------------------------------------------------- discovery
progressFcn(0.05, 'Discovering model files...');

availableModels = discoverModelFiles(modelsFolder);
if isempty(availableModels)
    error('buildParentModelCore:NoModelsFound', ...
        'No .slx or .mdl files were found under:\n%s', modelsFolder);
end

modelNames = cell(numModels, 1);
modelPaths = cell(numModels, 1);
for modelIndex = 1:numModels
    requestedName = selectedModels{modelIndex};
    matchIndexes = find(strcmpi(availableModels.names, requestedName));
    if isempty(matchIndexes)
        error('buildParentModelCore:ModelNotFound', ...
            ['Referenced model "%s" was not found under:\n%s\n\n', ...
             'Available models:\n%s'], ...
            requestedName, modelsFolder, ...
            strjoin(sort(availableModels.names), newline));
    end
    if numel(matchIndexes) > 1
        error('buildParentModelCore:DuplicateModelName', ...
            ['Multiple files named "%s" were found:\n\n%s\n\n', ...
             'Referenced-model filenames must be unique. Rename the files ', ...
             'or keep only one of them.'], ...
            requestedName, strjoin(availableModels.paths(matchIndexes), newline));
    end
    modelNames{modelIndex} = availableModels.names{matchIndexes(1)};
    modelPaths{modelIndex} = availableModels.paths{matchIndexes(1)};
end

% ------------------------------------------------------------ load models
progressFcn(0.15, 'Loading referenced models...');

searchPath = genpath(modelsFolder);
if ~isempty(searchPath)
    addpath(searchPath);
end

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
        ['A referenced model file exists but Simulink refused to open ', ...
         'it. Common reasons: it was saved in a NEWER Simulink version, ', ...
         'the file is damaged, or it needs libraries/models that are not ', ...
         'on the MATLAB path.\n\nFile:\n%s\n\nDetails:\n%s'], ...
        modelPaths{modelIndex}, errorChainText(loadError));
end

parentCreated = false;
try
    % ---------------------------------------------------- configuration
    progressFcn(0.3, 'Checking configuration parameters...');

    configParamNames = options.ConfigParameters;
    if ischar(configParamNames)
        configParamNames = {configParamNames};
    elseif isstring(configParamNames)
        configParamNames = cellstr(configParamNames(:));
    end
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
                configProblems{end + 1} = sprintf( ...
                    'Could not read "%s" from model "%s": %s', ...
                    parameter, modelNames{modelIndex}, readError.message); %#ok<AGROW>
                readable = false;
                break;
            end
        end
        if ~readable
            continue;
        end

        allMatch = true;
        for modelIndex = 2:numModels
            if ~strcmpi(values{modelIndex}, values{1})
                allMatch = false;
                configProblems{end + 1} = sprintf( ...
                    ['"%s" differs between models:\n  %s = %s\n  %s = %s'], ...
                    parameter, modelNames{1}, values{1}, ...
                    modelNames{modelIndex}, values{modelIndex}); %#ok<AGROW>
            end
        end
        if allMatch
            configParamNames{paramIndex} = parameter;
            configParamValues{paramIndex} = values{1};
        end
    end

    if ~isempty(configProblems)
        error('buildParentModelCore:ConfigMismatch', ...
            'Referenced-model configuration mismatch:\n\n%s\n\n%s', ...
            strjoin(configProblems, newline), ...
            'Make these settings identical in every referenced model and run again.');
    end

    % keep only parameters that were successfully checked
    okParams = ~cellfun('isempty', configParamValues);
    result.ConfigParamNames = configParamNames(okParams);
    result.ConfigParamValues = configParamValues(okParams);

    % --------------------------------------------------------- interfaces
    progressFcn(0.4, 'Reading model interfaces...');

    modelInfo = struct( ...
        'Name',        modelNames, ...
        'Path',        modelPaths, ...
        'InputNames',  cell(numModels, 1), ...
        'OutputNames', cell(numModels, 1));

    for modelIndex = 1:numModels
        [inputNames, outputNames] = getRootPortNames(modelNames{modelIndex});
        modelInfo(modelIndex).InputNames = inputNames;
        modelInfo(modelIndex).OutputNames = outputNames;
    end

    % NOTE: modelInfo(k).InputNames must be copied element-by-element.
    % Writing 'InputNames', modelInfo.InputNames directly would expand the
    % struct-array field into multiple arguments (comma-list) and break
    % struct() whenever there is more than one model.
    result.Models = struct( ...
        'Name',        modelNames, ...
        'Path',        modelPaths, ...
        'InputNames',  cell(numModels, 1), ...
        'OutputNames', cell(numModels, 1));
    for modelIndex = 1:numModels
        result.Models(modelIndex).InputNames = modelInfo(modelIndex).InputNames;
        result.Models(modelIndex).OutputNames = modelInfo(modelIndex).OutputNames;
    end

    % ---------------------------------------------------------------- plan
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
                if destinationIndex == sourceIndex
                    continue;
                end
                destinationInputs = modelInfo(destinationIndex).InputNames;
                for inputIndex = 1:numel(destinationInputs)
                    if inputConnected{destinationIndex}(inputIndex)
                        continue;
                    end
                    if strcmp(normKey(destinationInputs{inputIndex}, caseInsensitive), outputKey)
                        inputConnected{destinationIndex}(inputIndex) = true;
                        internalConnections(end + 1) = struct( ...
                            'SrcModelIndex', sourceIndex, ...
                            'SrcPortIndex',  outputIndex, ...
                            'DstModelIndex', destinationIndex, ...
                            'DstPortIndex',  inputIndex, ...
                            'SrcModel',      modelInfo(sourceIndex).Name, ...
                            'SrcPort',       outputs{outputIndex}, ...
                            'DstModel',      modelInfo(destinationIndex).Name, ...
                            'DstPort',       destinationInputs{inputIndex}); %#ok<AGROW>
                    end
                end
            end
        end
        % note self-matches (input and output with the same name in one model)
        for outputIndex = 1:numel(outputs)
            outputKey = normKey(outputs{outputIndex}, caseInsensitive);
            for inputIndex = 1:numel(inputs)
                if strcmp(normKey(inputs{inputIndex}, caseInsensitive), outputKey)
                    note = sprintf( ...
                        ['Note: model "%s" has an input and an output both ', ...
                         'named "%s" - self-connections are skipped.'], ...
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

    % duplicate output names across models (first model in the list wins)
    flatOutputs = {};
    flatOwners = zeros(0, 1);
    for modelIndex = 1:numModels
        outputs = modelInfo(modelIndex).OutputNames(:);
        flatOutputs = [flatOutputs; outputs]; %#ok<AGROW>
        flatOwners = [flatOwners; repmat(modelIndex, numel(outputs), 1)]; %#ok<AGROW>
    end
    if ~isempty(flatOutputs)
        flatKeys = cellfun(@(s) normKey(s, caseInsensitive), flatOutputs, ...
            'UniformOutput', false);
        connectionSourceKeys = cellfun(@(s) normKey(s, caseInsensitive), ...
            {internalConnections.SrcPort}, 'UniformOutput', false);
        [uniqueKeys, ~, keyGroups] = unique(flatKeys);
        for keyIndex = 1:numel(uniqueKeys)
            thisGroup = find(keyGroups == keyIndex);
            ownerIndexes = unique(flatOwners(thisGroup));
            if numel(ownerIndexes) <= 1
                continue;
            end
            if ~any(strcmp(connectionSourceKeys, uniqueKeys{keyIndex}))
                continue;
            end
            ownerNames = modelNames(ownerIndexes);
            result.Warnings{end + 1} = sprintf( ...
                ['Output name "%s" exists in more than one model (%s). ', ...
                 'Only "%s" (first in the list) feeds internal connections; ', ...
                 'the others are exposed as root outputs only.'], ...
                flatOutputs{thisGroup(1)}, strjoin(ownerNames(:), ', '), ...
                ownerNames{1}); %#ok<AGROW>
        end
    end

    % root inputs for still-unconnected inputs (shared per name)
    rootInputs = result.RootInputs;
    groupKeys = {};
    for destinationIndex = 1:numModels
        destinationInputs = modelInfo(destinationIndex).InputNames;
        for inputIndex = 1:numel(destinationInputs)
            if inputConnected{destinationIndex}(inputIndex)
                continue;
            end
            key = normKey(destinationInputs{inputIndex}, caseInsensitive);
            groupPosition = find(strcmp(groupKeys, key), 1);
            if isempty(groupPosition)
                groupKeys{end + 1} = key; %#ok<AGROW>
                rootInputs(end + 1) = struct( ...
                    'Name',                      destinationInputs{inputIndex}, ...
                    'DestinationModels',         {{}}, ...
                    'DestinationPorts',          {{}}, ...
                    'DestinationModelIndexes',   [], ...
                    'DestinationPortIndexes',    []); %#ok<AGROW>
                groupPosition = numel(rootInputs);
            end
            rootInputs(groupPosition).DestinationModels{end + 1} = ...
                modelInfo(destinationIndex).Name; %#ok<AGROW>
            rootInputs(groupPosition).DestinationPorts{end + 1} = ...
                destinationInputs{inputIndex}; %#ok<AGROW>
            rootInputs(groupPosition).DestinationModelIndexes(end + 1) = ...
                destinationIndex; %#ok<AGROW>
            rootInputs(groupPosition).DestinationPortIndexes(end + 1) = ...
                inputIndex; %#ok<AGROW>
        end
    end
    result.RootInputs = rootInputs;
    result.Counts.RootInputs = numel(rootInputs);

    % case-variant root input warning
    for inputIndex = 1:numel(rootInputs)
        spellings = unique(rootInputs(inputIndex).DestinationPorts);
        if numel(spellings) > 1
            quoted = cellfun(@(s) ['''' s ''''], spellings, ...
                'UniformOutput', false);
            result.Notes{end + 1} = sprintf( ...
                ['Input names %s differ only by letter case - one shared ', ...
                 'root Inport "%s" feeds all of them.'], ...
                strjoin(quoted, ', '), rootInputs(inputIndex).Name); %#ok<AGROW>
        end
    end

    % root outputs (every referenced-model output, unique names)
    rootOutputs = result.RootOutputs;
    usedTopNames = {};
    for sourceIndex = 1:numModels
        outputs = modelInfo(sourceIndex).OutputNames;
        for outputIndex = 1:numel(outputs)
            requestedName = outputs{outputIndex};
            if any(strcmp(usedTopNames, requestedName))
                requestedName = sprintf('%s_%s', ...
                    modelInfo(sourceIndex).Name, outputs{outputIndex});
            end
            baseName = requestedName;
            suffix = 2;
            while any(strcmp(usedTopNames, requestedName))
                requestedName = sprintf('%s_%d', baseName, suffix);
                suffix = suffix + 1;
            end
            usedTopNames{end + 1} = requestedName; %#ok<AGROW>
            rootOutputs(end + 1) = struct( ...
                'Name',             requestedName, ...
                'SourceModel',      modelInfo(sourceIndex).Name, ...
                'SourcePort',       outputs{outputIndex}, ...
                'SourceModelIndex', sourceIndex, ...
                'SourcePortIndex',  outputIndex); %#ok<AGROW>
        end
    end
    result.RootOutputs = rootOutputs;
    result.Counts.RootOutputs = numel(rootOutputs);

    result.Notes = [result.Notes; selfMatchNotes];

    if cancelFcn()
        result.Cancelled = true;
        closeLoadedModels(loadedByUs);
        return;
    end

    % ------------------------------------------------------------- preview
    if result.PreviewOnly
        % FIX 1: Respect options.CloseReferencedModels preference on successful preview
        if options.CloseReferencedModels
            closeLoadedModels(loadedByUs);
        end
        result.Success = true;
        progressFcn(1, 'Preview complete.');
        return;
    end

    % --------------------------------------------------------------- build
    progressFcn(0.6, 'Creating the parent model...');

    if isfile(targetModelFile) && options.BackupExisting
        backupFile = [targetModelFile '.bak'];
        movefile(targetModelFile, backupFile);
        result.BackupFile = backupFile;
    end

    if bdIsLoaded(targetModel)
        close_system(targetModel, 0);
    end

    new_system(targetModel);
    parentCreated = true;
    open_system(targetModel);
    set_param(targetModel, 'Location', [100 100 1500 850]);

    for paramIndex = 1:numel(result.ConfigParamNames)
        set_param(targetModel, result.ConfigParamNames{paramIndex}, ...
            result.ConfigParamValues{paramIndex});
    end

    % the parent model only routes signals between referenced models -
    % no continuous states: fixed-step, discrete solver
    set_param(targetModel, ...
        'SolverType', 'Fixed-step', ...
        'Solver', 'FixedStepDiscrete');

    if strcmp(connectionMethod, 'fromgoto')
        % ------------------------------------------------------------
        % From/Goto style (like the team script): no crossing lines.
        % Every model input gets a From block, every output a Goto
        % block; signals meet through matching tags. Feedback signals
        % (produced by a model later in the list) get a Unit Delay when
        % AutoDelayFeedback is on.
        % ------------------------------------------------------------
        progressFcn(0.65, 'Adding Model Reference blocks (From/Goto style)...');

        % one canonical tag per normalized signal name (first spelling
        % wins; tags are made unique so two signals can never merge -
        % a clash carries the producing model's name, e.g. 1_pump)
        signalKeys = {};
        signalNames = {};
        signalModels = {};
        inputKeys = {};
        modelOutputKeys = cell(numModels, 1);
        % FIX 3: Preallocated modelInputKeys to avoid dynamic growth warnings
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
                    % two different port names clean up to the same
                    % tag (e.g. "*1" and ".1" both become "1") -
                    % qualify it with the producing model's name so
                    % it stays meaningful, numbers only as fallback
                    if suffix == 2
                        modelTag = safeName(signalModels{signalIndex});
                        if ~isempty(modelTag) && ...
                                ~any(strcmp(usedTags, ...
                                [baseTag '_' modelTag]))
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

        % highest list position of any producer of each signal
        % (feedback heuristic: a signal whose producer appears later in
        % the list than the model consuming it is a feedback)
        maxProducerOrder = containers.Map('KeyType', 'char', 'ValueType', 'double');
        firstProducerOrder = containers.Map('KeyType', 'char', 'ValueType', 'double');
        for modelIndex = 1:numModels
            for outputIndex = 1:numel(modelOutputKeys{modelIndex})
                key = modelOutputKeys{modelIndex}{outputIndex};
                if ~isKey(firstProducerOrder, key)
                    firstProducerOrder(key) = modelIndex;
                end
                if isKey(maxProducerOrder, key)
                    maxProducerOrder(key) = max(maxProducerOrder(key), modelIndex);
                else
                    maxProducerOrder(key) = modelIndex;
                end
            end
        end

        % lowest list position of any consumer of each signal
        % (retained for diagnostics; the delays themselves now sit at
        % the INPUT of each consumer - see the input loop below)
        minConsumerOrder = containers.Map('KeyType', 'char', 'ValueType', 'double');
        for modelIndex = 1:numModels
            for inputIndex = 1:numel(modelInputKeys{modelIndex})
                key = modelInputKeys{modelIndex}{inputIndex};
                if isKey(minConsumerOrder, key)
                    minConsumerOrder(key) = min(minConsumerOrder(key), modelIndex);
                else
                    minConsumerOrder(key) = modelIndex;
                end
            end
        end

        % warn when one signal name is produced by several models (they
        % would fight over the same Goto tag)
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

        % common From/Goto width from the longest signal tag
        longestTagLength = 0;
        for tagIndex = 1:numel(usedTags)
            longestTagLength = max(longestTagLength, numel(usedTags{tagIndex}));
        end
        commonFromGotoWidth = max(100, 8 * longestTagLength + 30);

        % geometry
        modelWidth = 300;
        minimumModelHeight = 120;
        % clear distance between blocks: user-settable, minimum 55 pt
        fromGap = fromModelGap;
        gotoGap = modelGotoGap;
        delayGap = fromToDelayGap;
        % horizontal layout needs room for both tag columns between
        % neighbouring models; the user value applies when it fits
        minModelGap = 4 * blockSpacing + 2 * commonFromGotoWidth + 40;
        if isempty(options.ModelToModelGap)
            modelToModelGap = max(400, minModelGap);
            verticalModelGap = 100;
        else
            userModelGap = max(50, round(double(options.ModelToModelGap)));
            modelToModelGap = max(minModelGap, userModelGap);
            verticalModelGap = userModelGap;
        end
        modelBaseY = 200;
        modelBaseX = max(500, 150 + commonFromGotoWidth + fromGap + 250);
        globalInportColor = '[0.65,0.90,0.65]';
        globalOutportColor = '[0.95,0.70,0.45]';
        ySpacingGlobal = 25;

        % ---- Model Reference blocks
        modelBlockNames = cell(numModels, 1);
        xCursor = modelBaseX;
        yCursor = 50;
        rightMostEdge = 0;
        for modelIndex = 1:numModels
            maximumPortCount = max([ ...
                numel(modelInfo(modelIndex).InputNames), ...
                numel(modelInfo(modelIndex).OutputNames), 1]);
            blockHeight = max(minimumModelHeight, maximumPortCount * 35);
            if strcmp(layoutStyle, 'horizontal')
                blockX = xCursor;
                blockY = modelBaseY;
                xCursor = xCursor + modelWidth + modelToModelGap;
            else
                blockX = modelBaseX;
                blockY = yCursor;
                yCursor = yCursor + blockHeight + verticalModelGap;
            end
            blockName = makeUniqueBlockName(targetModel, modelInfo(modelIndex).Name);
            modelBlockNames{modelIndex} = blockName;
            modelInfo(modelIndex).BlockPos = [blockX, blockY, ...
                blockX + modelWidth, blockY + blockHeight];
            add_block('simulink/Ports & Subsystems/Model', ...
                [targetModel '/' blockName], ...
                'ModelName', modelInfo(modelIndex).Name, ...
                'Position', modelInfo(modelIndex).BlockPos);
            if colorBlocks
                set_param([targetModel '/' blockName], ...
                    'BackgroundColor', paletteColor(modelIndex));
            end
            rightMostEdge = max(rightMostEdge, ...
                blockX + modelWidth + gotoGap + commonFromGotoWidth);
        end

        % update once so the Model blocks expose their real port handles
        set_param(targetModel, 'SimulationCommand', 'update');

        progressFcn(0.75, 'Reading the model ports...');
        for modelIndex = 1:numModels
            portHandles = get_param( ...
                [targetModel '/' modelBlockNames{modelIndex}], 'PortHandles');
            inHandles = portHandles.Inport(:);
            outHandles = portHandles.Outport(:);
            if numel(inHandles) ~= numel(modelInfo(modelIndex).InputNames) || ...
                    numel(outHandles) ~= numel(modelInfo(modelIndex).OutputNames)
                error('buildParentModelCore:PortMismatch', ...
                    ['Port mismatch for referenced model "%s". The model may ', ...
                     'have changed since it was scanned - refresh and try ', ...
                     'again.'], modelInfo(modelIndex).Name);
            end
            modelInfo(modelIndex).InputHandles = inHandles;
            modelInfo(modelIndex).OutputHandles = outHandles;
            inputPortYs = zeros(numel(inHandles), 1);
            for portIndex = 1:numel(inHandles)
                portPosition = get_param(inHandles(portIndex), 'Position');
                inputPortYs(portIndex) = portPosition(2);
            end
            modelInfo(modelIndex).InputPortYs = inputPortYs;
            outputPortYs = zeros(numel(outHandles), 1);
            for portIndex = 1:numel(outHandles)
                portPosition = get_param(outHandles(portIndex), 'Position');
                outputPortYs(portIndex) = portPosition(2);
            end
            modelInfo(modelIndex).OutputPortYs = outputPortYs;
        end

        progressFcn(0.8, 'Adding From/Goto blocks and connections...');

        autoDelayCount = 0;
        % per-signal From/Goto counters: the number in speed_From_2
        % means '2nd From block reading speed', not a port index
        fromCountByTag = containers.Map('KeyType', 'char', ...
                                        'ValueType', 'double');
        gotoCountByTag = containers.Map('KeyType', 'char', ...
                                        'ValueType', 'double');
        for modelIndex = 1:numModels
            blockPos = modelInfo(modelIndex).BlockPos;
            for inputIndex = 1:numel(modelInfo(modelIndex).InputNames)
                sig = modelInfo(modelIndex).InputNames{inputIndex};
                key = normKey(sig, caseInsensitive);
                tag = tagOf(key);
                signalY = modelInfo(modelIndex).InputPortYs(inputIndex);

                % block name from the signal TAG with a per-signal
                % counter: <tag>_From_<k> - speed_From_1, speed_From_2
                % are the 1st and 2nd models reading 'speed'. k starts
                % at 1 per signal and never repeats, whatever the port
                % indexes are (the port index produced repeated and
                % missing numbers, e.g. from_3, from_3, from_4)
                fromCounter = 1;
                if isKey(fromCountByTag, tag)
                    fromCounter = fromCountByTag(tag) + 1;
                end
                fromCountByTag(tag) = fromCounter;
                fromName = makeUniqueBlockName(targetModel, ...
                    sprintf('%s_From_%d', tag, fromCounter));
                % feedback = fed from BELOW (producer later in the
                % list) or the model consuming its OWN output signal.
                % Both get a delay at the INPUT (inport level).
                % self-feed only counts when this model is the ONLY
                % producer of the signal (its From then truly reads its
                % own Goto); when other models also produce it, the
                % normal top->bottom / bottom->top rules apply
                selfFeed = isSelfFeeding(modelOutputKeys, modelIndex, key) && ...
                    isKey(firstProducerOrder, key) && ...
                    firstProducerOrder(key) == modelIndex && ...
                    isKey(maxProducerOrder, key) && ...
                    maxProducerOrder(key) == modelIndex;
                inputIsFeedback = autoDelayFeedback && ( ...
                    (isKey(maxProducerOrder, key) && ...
                     maxProducerOrder(key) > modelIndex) || selfFeed);
                if inputIsFeedback
                    % From -> gap -> UnitDelay (40 pt) -> gap -> model
                    fromRight = blockPos(1) - ...
                        (fromModelGap + fromToDelayGap + 40);
                else
                    fromRight = blockPos(1) - fromGap;
                end
                fromLeft = fromRight - commonFromGotoWidth;
                add_block('simulink/Signal Routing/From', ...
                    [targetModel '/' fromName], 'GotoTag', tag, ...
                    'Position', [fromLeft, signalY - 10, fromRight, signalY + 10]);
                if colorBlocks && isKey(firstProducerOrder, key)
                    set_param([targetModel '/' fromName], ...
                        'BackgroundColor', paletteColor(firstProducerOrder(key)));
                end

                if inputIsFeedback
                    % the delay sits at the INPORT level - between the
                    % From block and this model input. Inputs fed from
                    % above (top -> bottom) stay undelayed, and each
                    % branch decides on its own.
                    delayName = makeUniqueBlockName(targetModel, ...
                        sprintf('UnitDelay_%d', autoDelayCount + 1));
                    delayLeft = fromRight + fromToDelayGap;
                    add_block('built-in/UnitDelay', ...
                        [targetModel '/' delayName], ...
                        'Position', [delayLeft, signalY - 10, ...
                                     delayLeft + 40, signalY + 10]);
                    if colorBlocks && isKey(firstProducerOrder, key)
                        set_param([targetModel '/' delayName], ...
                            'BackgroundColor', ...
                            paletteColor(firstProducerOrder(key)));
                    end
                    add_line(targetModel, [fromName '/1'], ...
                        [delayName '/1'], 'autorouting', 'off');
                    add_line(targetModel, [delayName '/1'], ...
                        sprintf('%s/%d', ...
                        modelBlockNames{modelIndex}, inputIndex), ...
                        'autorouting', 'off');
                    autoDelayCount = autoDelayCount + 1;
                    if selfFeed
                        result.Notes{end + 1} = sprintf( ...
                            ['Note: model "%s" both produces and consumes ', ...
                             '"%s" (its From would read its own Goto) - a ', ...
                             'Unit Delay was inserted at its input to ', ...
                             'break the self-loop.'], ...
                            modelInfo(modelIndex).Name, sig); %#ok<AGROW>
                    end
                else
                    add_line(targetModel, [fromName '/1'], ...
                        sprintf('%s/%d', ...
                        modelBlockNames{modelIndex}, inputIndex), ...
                        'autorouting', 'off');
                end
            end

            for outputIndex = 1:numel(modelInfo(modelIndex).OutputNames)
                sig = modelInfo(modelIndex).OutputNames{outputIndex};
                key = normKey(sig, caseInsensitive);
                tag = tagOf(key);
                signalY = modelInfo(modelIndex).OutputPortYs(outputIndex);

                % feedback Unit Delays are NOT inserted on the output
                % side: they sit at the destination model's INPUT
                % (inport level), inserted in the input loop above
                gotoLeft = blockPos(3) + gotoGap;

                % block name from the signal TAG with a per-signal
                % counter: <tag>_Goto_<k> - torque_Goto_1, torque_Goto_2
                % are the 1st and 2nd models producing 'torque'. k
                % starts at 1 per signal; the port index is not used
                gotoCounter = 1;
                if isKey(gotoCountByTag, tag)
                    gotoCounter = gotoCountByTag(tag) + 1;
                end
                gotoCountByTag(tag) = gotoCounter;
                gotoName = makeUniqueBlockName(targetModel, ...
                    sprintf('%s_Goto_%d', tag, gotoCounter));
                add_block('simulink/Signal Routing/Goto', ...
                    [targetModel '/' gotoName], 'GotoTag', tag, ...
                    'Position', [gotoLeft, signalY - 10, ...
                                 gotoLeft + commonFromGotoWidth, signalY + 10]);
                if colorBlocks
                    set_param([targetModel '/' gotoName], ...
                        'BackgroundColor', paletteColor(modelIndex));
                end
                add_line(targetModel, ...
                    sprintf('%s/%d', modelBlockNames{modelIndex}, outputIndex), ...
                    [gotoName '/1'], 'autorouting', 'off');
            end
        end

        progressFcn(0.88, 'Adding global inputs and outputs...');

        % global inputs: signals that no model produces
        uniqueInputKeyList = unique(inputKeys);
        globalInputKeyList = setdiff(uniqueInputKeyList, ...
            uniqueOutputKeyList, 'stable');

        for g = 1:numel(globalInputKeyList)
            key = globalInputKeyList{g};
            tag = tagOf(key);
            signalY = 50 + g * ySpacingGlobal;
            inBlockName = makeUniqueBlockName(targetModel, tag);
            add_block('simulink/Sources/In1', ...
                [targetModel '/' inBlockName], ...
                'Port', num2str(g), ...
                'Position', [50, signalY, 80, signalY + 20]);
            if colorBlocks
                set_param([targetModel '/' inBlockName], ...
                    'BackgroundColor', globalInportColor);
            end
            gotoBlockName = makeUniqueBlockName(targetModel, ['Goto_' tag]);
            globalGotoLeft = 80 + blockSpacing;
            add_block('simulink/Signal Routing/Goto', ...
                [targetModel '/' gotoBlockName], 'GotoTag', tag, ...
                'Position', [globalGotoLeft, signalY, ...
                             globalGotoLeft + commonFromGotoWidth, ...
                             globalGotoLeft + commonFromGotoWidth + 30, ... % Adjusted size matching standard
                             signalY + 20]);
            add_line(targetModel, [inBlockName '/1'], [gotoBlockName '/1'], ...
                'autorouting', 'off');
        end

        % global outputs: every unique model output
        % FIX 4: Realign result.RootOutputs in From/Goto mode to match generated ports.
        globalFromX = rightMostEdge + max(300, 2 * blockSpacing + 100);
        globalOutX = globalFromX + commonFromGotoWidth + blockSpacing;
        uniqueRootOutputs = struct('Name', {}, 'SourceModel', {}, 'SourcePort', {}, ...
                                   'SourceModelIndex', {}, 'SourcePortIndex', {});
        for g = 1:numel(uniqueOutputKeyList)
            key = uniqueOutputKeyList{g};
            tag = tagOf(key);
            signalY = 50 + g * ySpacingGlobal;
            fromBlockName = makeUniqueBlockName(targetModel, ['From_' tag]);
            add_block('simulink/Signal Routing/From', ...
                [targetModel '/' fromBlockName], 'GotoTag', tag, ...
                'Position', [globalFromX, signalY, ...
                             globalFromX + commonFromGotoWidth, signalY + 20]);
            if colorBlocks && isKey(firstProducerOrder, key)
                set_param([targetModel '/' fromBlockName], ...
                    'BackgroundColor', paletteColor(firstProducerOrder(key)));
            end
            outBlockName = makeUniqueBlockName(targetModel, tag);
            add_block('simulink/Sinks/Out1', ...
                [targetModel '/' outBlockName], ...
                'Port', num2str(g), ...
                'Position', [globalOutX, signalY, globalOutX + 30, signalY + 20]);
            if colorBlocks
                set_param([targetModel '/' outBlockName], ...
                    'BackgroundColor', globalOutportColor);
            end
            add_line(targetModel, [fromBlockName '/1'], [outBlockName '/1'], ...
                'autorouting', 'off');

            % Gather primary producer details to match this unique outport port configuration
            prodIndex = 1;
            if isKey(firstProducerOrder, key)
                prodIndex = firstProducerOrder(key);
            end
            portIdx = find(strcmp(modelOutputKeys{prodIndex}, key), 1);
            if isempty(portIdx)
                portIdx = 1;
            end
            uniqueRootOutputs(g) = struct( ...
                'Name',             tag, ...
                'SourceModel',      modelInfo(prodIndex).Name, ...
                'SourcePort',       modelInfo(prodIndex).OutputNames{portIdx}, ...
                'SourceModelIndex', prodIndex, ...
                'SourcePortIndex',  portIdx);
        end
        result.RootOutputs = uniqueRootOutputs;
        result.Counts.RootOutputs = numel(uniqueRootOutputs);
        result.Counts.Internal = numel(internalConnections);
        result.Counts.RootInputs = numel(globalInputKeyList);
        if autoDelayCount > 0
            result.Notes{end + 1} = sprintf( ...
                'Inserted %d Unit Delay(s) on feedback signals automatically.', ...
                autoDelayCount); %#ok<AGROW>
        end

    else

    % layout constants (same visual style as the original script)
    modelStartX = 450;
    modelStartY = 80;
    modelWidth = 240;
    minimumModelHeight = 160;
    modelGap = 100;
    inportX = 50;
    outportX = modelStartX + modelWidth + 350;
    portWidth = 35;
    portHeight = 20;
    minPortSpacing = 45;

    if options.TidyLayout
        routeMode = 'smart';
    else
        routeMode = 'on';
    end

    progressFcn(0.65, 'Adding Model Reference blocks...');

    modelBlockNames = cell(numModels, 1);
    modelTopBottom = zeros(numModels, 2);
    currentModelY = modelStartY;
    currentModelX = modelStartX;
    for modelIndex = 1:numModels
        maximumPortCount = max([ ...
            numel(modelInfo(modelIndex).InputNames), ...
            numel(modelInfo(modelIndex).OutputNames), 1]);
        currentModelHeight = max(minimumModelHeight, maximumPortCount * 35);

        blockName = makeUniqueBlockName(targetModel, modelInfo(modelIndex).Name);
        modelBlockNames{modelIndex} = blockName;

        if strcmp(layoutStyle, 'horizontal')
            blockPosition = [currentModelX, currentModelY, ...
                currentModelX + modelWidth, currentModelY + currentModelHeight];
            currentModelX = currentModelX + modelWidth + modelGap;
        else
            blockPosition = [modelStartX, currentModelY, ...
                modelStartX + modelWidth, currentModelY + currentModelHeight];
            currentModelY = currentModelY + currentModelHeight + modelGap;
        end

        add_block('simulink/Ports & Subsystems/Model', ...
            [targetModel '/' blockName], ...
            'ModelName', modelInfo(modelIndex).Name, ...
            'Position', blockPosition);

        if colorBlocks
            set_param([targetModel '/' blockName], ...
                'BackgroundColor', paletteColor(modelIndex));
        end

        modelTopBottom(modelIndex, :) = [blockPosition(2), blockPosition(4)];
    end

    if strcmp(layoutStyle, 'horizontal')
        % keep the root Outports to the right of the last model
        outportX = currentModelX - modelGap + 300;
    end

    % Update once only - updating after every block invalidates handles.
    set_param(targetModel, 'SimulationCommand', 'update');

    progressFcn(0.72, 'Reading fresh port handles...');

    for modelIndex = 1:numModels
        portHandles = get_param([targetModel '/' modelBlockNames{modelIndex}], ...
            'PortHandles');
        inputHandles = portHandles.Inport(:);
        outputHandles = portHandles.Outport(:);

        if numel(inputHandles) ~= numel(modelInfo(modelIndex).InputNames) || ...
                numel(outputHandles) ~= numel(modelInfo(modelIndex).OutputNames)
            error('buildParentModelCore:PortMismatch', ...
                ['Port mismatch for referenced model "%s". The model may ', ...
                 'have changed since it was scanned - refresh and try again.'], ...
                modelInfo(modelIndex).Name);
        end

        modelInfo(modelIndex).InputHandles = inputHandles;
        modelInfo(modelIndex).OutputHandles = outputHandles;
    end

    progressFcn(0.8, 'Connecting matching outputs to inputs...');

    autoDelayCount = 0;
    for connectionIndex = 1:numel(internalConnections)
        connection = internalConnections(connectionIndex);
        srcHandle = modelInfo(connection.SrcModelIndex).OutputHandles(connection.SrcPortIndex);
        dstHandle = modelInfo(connection.DstModelIndex).InputHandles(connection.DstPortIndex);
        if autoDelayFeedback && (connection.SrcModelIndex > ...
                connection.DstModelIndex || ...
                connection.SrcModelIndex == connection.DstModelIndex)
            % feedback in the listed order: the source model comes
            % after the destination model (bottom -> top), or a model
            % feeds its OWN input - delay this branch AT THE
            % DESTINATION INPUT to prevent an algebraic loop
            srcPos = get_param([targetModel '/' ...
                modelBlockNames{connection.SrcModelIndex}], 'Position');
            % in line with that input port so the line runs straight in
            dstPortPos = get_param(dstHandle, 'Position');
            delayLeft = round(dstPortPos(1)) - 40 - blockSpacing;
            if delayLeft < srcPos(3) + blockSpacing
                % very tight gap - fall back to the middle
                delayLeft = round((srcPos(3) + dstPortPos(1)) / 2) - 20;
            end
            delayY = round(dstPortPos(2));
            delayName = makeUniqueBlockName(targetModel, ...
                sprintf('UnitDelay_%d', autoDelayCount + 1));
            add_block('built-in/UnitDelay', [targetModel '/' delayName], ...
                'Position', [delayLeft, delayY - 10, ...
                             delayLeft + 40, delayY + 10]);
            delayPorts = get_param([targetModel '/' delayName], 'PortHandles');
            addLineRouted(targetModel, routeMode, srcHandle, delayPorts.Inport(1));
            addLineRouted(targetModel, routeMode, delayPorts.Outport(1), dstHandle);
            autoDelayCount = autoDelayCount + 1;
            if connection.SrcModelIndex == connection.DstModelIndex
                result.Notes{end + 1} = sprintf( ...
                    ['Note: model "%s" consumes its own output signal ', ...
                     '- a Unit Delay was inserted at its input to ', ...
                     'break the self-loop.'], connection.SrcModel); %#ok<AGROW>
            end
        else
            addLineRouted(targetModel, routeMode, srcHandle, dstHandle);
        end
    end
    if autoDelayCount > 0
        result.Notes{end + 1} = sprintf( ...
            'Inserted %d Unit Delay(s) on feedback signals automatically.', ...
            autoDelayCount); %#ok<AGROW>
    end

    % ---- shared root Inports, aligned with the ports they feed
    progressFcn(0.88, 'Creating shared root Inports...');

    if ~isempty(rootInputs)
        if strcmp(layoutStyle, 'horizontal')
            % simple left column, in the listed order
            order = 1:numel(rootInputs);
            spacedYs = (1:numel(rootInputs))' * minPortSpacing + 50;
        else
            desiredY = zeros(numel(rootInputs), 1);
            for inputIndex = 1:numel(rootInputs)
                ys = zeros(numel(rootInputs(inputIndex).DestinationModelIndexes), 1);
                for d = 1:numel(ys)
                    modelIndex = rootInputs(inputIndex).DestinationModelIndexes(d);
                    portIndex = rootInputs(inputIndex).DestinationPortIndexes(d);
                    portCount = numel(modelInfo(modelIndex).InputNames);
                    ys(d) = portY(modelTopBottom(modelIndex, :), portIndex, portCount);
                end
                desiredY(inputIndex) = mean(ys);
            end
            [order, spacedYs] = spacedOrder(desiredY, minPortSpacing);
        end

        for position = 1:numel(order)
            inputIndex = order(position);
            inputBlockName = makeUniqueBlockName(targetModel, ...
                rootInputs(inputIndex).Name);
            add_block('simulink/Sources/In1', ...
                [targetModel '/' inputBlockName], ...
                'Port', num2str(position), ...
                'Position', [inportX, round(spacedYs(position)), ...
                             inportX + portWidth, round(spacedYs(position)) + portHeight]);

            inputPortHandles = get_param([targetModel '/' inputBlockName], ...
                'PortHandles');
            rootSourceHandle = inputPortHandles.Outport;

            for d = 1:numel(rootInputs(inputIndex).DestinationModelIndexes)
                modelIndex = rootInputs(inputIndex).DestinationModelIndexes(d);
                portIndex = rootInputs(inputIndex).DestinationPortIndexes(d);
                addLineRouted(targetModel, routeMode, rootSourceHandle, ...
                    modelInfo(modelIndex).InputHandles(portIndex));
            end
        end
    end

    % ---- one root Outport per referenced-model output, aligned to source
    progressFcn(0.94, 'Creating root Outports...');

    if ~isempty(rootOutputs)
        if strcmp(layoutStyle, 'horizontal')
            % simple right column, in the listed order
            order = 1:numel(rootOutputs);
            spacedYs = (1:numel(rootOutputs))' * minPortSpacing + 50;
        else
            desiredY = zeros(numel(rootOutputs), 1);
            for outputIndex = 1:numel(rootOutputs)
                modelIndex = rootOutputs(outputIndex).SourceModelIndex;
                portIndex = rootOutputs(outputIndex).SourcePortIndex;
                portCount = numel(modelInfo(modelIndex).OutputNames);
                desiredY(outputIndex) = portY(modelTopBottom(modelIndex, :), ...
                    portIndex, portCount);
            end
            [order, spacedYs] = spacedOrder(desiredY, minPortSpacing);
        end

        for position = 1:numel(order)
            outputIndex = order(position);
            outputBlockName = makeUniqueBlockName(targetModel, ...
                rootOutputs(outputIndex).Name);
            add_block('simulink/Sinks/Out1', ...
                [targetModel '/' outputBlockName], ...
                'Port', num2str(position), ...
                'Position', [outportX, round(spacedYs(position)), ...
                             outportX + portWidth, round(spacedYs(position)) + portHeight]);

            % port-path syntax (robust for branching sources)
            sourcePortPath = sprintf('%s/%d', ...
                modelBlockNames{rootOutputs(outputIndex).SourceModelIndex}, ...
                rootOutputs(outputIndex).SourcePortIndex);
            destinationPortPath = sprintf('%s/1', outputBlockName);
            addLineRouted(targetModel, routeMode, sourcePortPath, destinationPortPath);
        end
    end

    end   % end of the lines-style build branch

    progressFcn(0.97, 'Updating diagram...');
    try
        set_param(targetModel, 'SimulationCommand', 'update');
    catch updateError
        % The diagram is fully built at this point - a failed update is a
        % validation problem, most often an algebraic loop between the
        % referenced models (a direct-feedthrough feedback chain such as
        % bike -> ... -> bike). That must not discard the build: save the
        % model anyway and let the app's Loop breaker tab fix the loop.
        result.Warnings{end + 1} = sprintf( ...
            ['Simulink could not update the diagram. Bottom -> top ', ...
             'signals and self-feeding signals already have automatic ', ...
             'Unit Delays, so a remaining algebraic loop is most likely ', ...
             'INSIDE one of the referenced models (a direct feedthrough ', ...
             'chain such as bike -> ... -> bike within it).\n\n', ...
             '%s\n\nThe model was still generated and saved. Check the ', ...
             'Loop breaker tab (Refresh list; untick the filters to see ', ...
             'which connections still need a Unit Delay), or add a ', ...
             'Unit Delay inside the referenced model itself.'], ...
            errorChainText(updateError)); %#ok<AGROW>
    end

    if cancelFcn()
        close_system(targetModel, 0);
        parentCreated = false;
        result.Cancelled = true;
        if ~isempty(result.BackupFile) && ~isfile(targetModelFile)
            try
                movefile(result.BackupFile, targetModelFile);
                result.BackupFile = '';
            catch
            end
        end
        closeLoadedModels(loadedByUs);
        return;
    end

    % ---- optional: wrap everything in one subsystem
    if options.WrapInSubsystem
        progressFcn(0.98, 'Wrapping contents in a subsystem...');
        try
            subsystemName = matlab.lang.makeValidName([targetModel '_Core']);
            % createSubsystem needs block HANDLES, not path names - search
            % from the diagram handle so find_system returns handles, and
            % 'Type','block' keeps the diagram itself out of the list.
            diagramHandle = get_param(targetModel, 'Handle');
            blockHandles = find_system(diagramHandle, 'SearchDepth', 1, ...
                'Type', 'block');
            Simulink.BlockDiagram.createSubsystem(blockHandles, ...
                'Name', subsystemName);
            result.SubsystemName = subsystemName;
        catch wrapError
            result.Warnings{end + 1} = sprintf( ...
                ['Could not wrap the contents in a subsystem (%s). The ', ...
                 'model was generated without wrapping.'], wrapError.message); %#ok<AGROW>
        end
    end

    progressFcn(0.99, 'Saving...');
    save_system(targetModel, targetModelFile);
    % keep the model's Simulink cache file (.slxc) next to the .slx:
    % the cache of a model that was not yet saved lands in the
    % current folder instead of the destination folder
    strayCacheFile = fullfile(pwd, [targetModel '.slxc']);
    destCacheFolder = fileparts(targetModelFile);
    if isempty(destCacheFolder)
        destCacheFolder = pwd;
    end
    
    % FIX 2: Check if pwd and output directory are the same to avoid redundant move warnings
    isSameDir = false;
    try
        strayDirInfo = dir(pwd);
        destDirInfo = dir(destCacheFolder);
        isSameDir = ~isempty(strayDirInfo) && ~isempty(destDirInfo) && ...
                    strcmp(strayDirInfo(1).folder, destDirInfo(1).folder);
    catch
        isSameDir = strcmpi(pwd, destCacheFolder);
    end
    
    if isfile(strayCacheFile) && ~isSameDir
        try
            movefile(strayCacheFile, fullfile(destCacheFolder, [targetModel '.slxc']));
        catch
            result.Warnings{end + 1} = sprintf( ...
                ['Could not move %s.slxc from the current folder ', ...
                 'to the model folder.'], targetModel); %#ok<AGROW>
        end
    end
    open_system(targetModel);

    % FIX 1: Respect options.CloseReferencedModels preference on successful generate
    if options.CloseReferencedModels
        closeLoadedModels(loadedByUs);
    end
    result.Success = true;
    progressFcn(1, 'Done.');

catch buildError
    % never leave a half-built model behind
    if parentCreated && bdIsLoaded(targetModel)
        close_system(targetModel, 0);
    end
    % if we moved the old file aside for a backup and never saved the new
    % one, put the original back
    if ~isempty(result.BackupFile) && ~isfile(targetModelFile)
        try
            movefile(result.BackupFile, targetModelFile);
            result.BackupFile = '';
        catch
        end
    end
    closeLoadedModels(loadedByUs);
    rethrow(buildError);
end
end

% =========================================================================
%  Local functions
% =========================================================================

function available = discoverModelFiles(modelsFolder)
%DISCOVERMODELFILES Find .slx/.mdl files recursively.

slxFiles = dir(fullfile(modelsFolder, '**', '*.slx'));
mdlFiles = dir(fullfile(modelsFolder, '**', '*.mdl'));
files = [slxFiles; mdlFiles];

available.names = cell(numel(files), 1);
available.paths = cell(numel(files), 1);
for fileIndex = 1:numel(files)
    [~, discoveredName] = fileparts(files(fileIndex).name);
    available.names{fileIndex} = discoveredName;
    available.paths{fileIndex} = fullfile(files(fileIndex).folder, ...
        files(fileIndex).name);
end
end

function [inputNames, outputNames] = getRootPortNames(modelName)
%GETROOTPORTNAMES Root-level Inport/Outport names, ordered by port number.

inputBlocks = find_system(char(modelName), ...
    'SearchDepth', 1, 'FollowLinks', 'on', ...
    'LookUnderMasks', 'all', 'BlockType', 'Inport');
outputBlocks = find_system(char(modelName), ...
    'SearchDepth', 1, 'FollowLinks', 'on', ...
    'LookUnderMasks', 'all', 'BlockType', 'Outport');

inputNames = orderedPortNames(inputBlocks, 'In');
outputNames = orderedPortNames(outputBlocks, 'Out');
end

function names = orderedPortNames(blocks, kind)
%ORDEREDPORTNAMES Block names sorted by port number (column cellstr).

names = {};
if isempty(blocks)
    return;
end

portNumbers = zeros(numel(blocks), 1);
for blockIndex = 1:numel(blocks)
    portNumber = str2double(get_param(blocks(blockIndex), 'Port'));
    if isnan(portNumber)
        error('buildParentModelCore:BadPortNumber', ...
            'Invalid port number on block: %s', getfullname(blocks(blockIndex)));
    end
    portNumbers(blockIndex) = portNumber;
end

[~, order] = sort(portNumbers);
sortedBlocks = blocks(order);
blockNames = get_param(sortedBlocks, 'Name');
if ischar(blockNames)
    blockNames = {blockNames};
end
blockNames = blockNames(:);

for blockIndex = 1:numel(blockNames)
    if isempty(strtrim(blockNames{blockIndex}))
        blockNames{blockIndex} = sprintf('%s%d', kind, portNumbers(order(blockIndex)));
    end
end

names = blockNames;
end

function key = normKey(name, caseInsensitive)
%NORMKEY Normalized comparison key for a port name.

if caseInsensitive
    key = lower(char(name));
else
    key = char(name);
end
end

function closeLoadedModels(loadedByUs)
%CLOSELOADEDMODELS Close only the models this engine loaded.

for modelIndex = 1:numel(loadedByUs)
    try
        if bdIsLoaded(loadedByUs{modelIndex})
            close_system(loadedByUs{modelIndex}, 0);
        end
    catch
        % closing must never break the main flow
    end
end
end

function uniqueName = makeUniqueBlockName(systemName, requestedName)
%MAKEUNIQUEBLOCKNAME Block name that does not collide in the system.

requestedName = strtrim(char(requestedName));
if isempty(requestedName)
    requestedName = 'Block';
end
requestedName = strrep(requestedName, '/', '_');

% collision handling: a name that already ends in _<number>
% (A_From_1, B_Goto_2, UnitDelay_3) keeps that shape and the
% number continues (A_From_1 taken -> A_From_2), so block names
% stay in the <name>_<n> pattern even when two models have the
% same signal name at the same port index; anything else gets
% _2, _3, ... appended as before (duplicate model name pump ->
% pump_2).
uniqueName = requestedName;
if ~isempty(regexp(uniqueName, '_\d+$', 'once'))
    parts = regexp(uniqueName, '^(.+)_(\d+)$', 'tokens', 'once');
    stem = parts{1};
    counter = str2double(parts{2});
    while blockExists([systemName '/' uniqueName])
        counter = counter + 1;
        uniqueName = sprintf('%s_%d', stem, counter);
    end
else
    suffix = 2;
    while blockExists([systemName '/' uniqueName])
        uniqueName = sprintf('%s_%d', requestedName, suffix);
        suffix = suffix + 1;
    end
end
end

function exists = blockExists(blockPath)
%BLOCKEXISTS True when a block exists at this path.

try
    get_param(blockPath, 'Handle');
    exists = true;
catch
    exists = false;
end
end

function addLineRouted(systemName, routeMode, varargin)
%ADDLINEROUTED add_line with smart routing, falling back to plain routing.

if strcmp(routeMode, 'smart')
    try
        add_line(systemName, varargin{:}, 'autorouting', 'smart');
        return;
    catch
        % fall back to basic autorouting on older releases
    end
end
add_line(systemName, varargin{:}, 'autorouting', 'on');
end

function y = portY(topBottom, portIndex, portCount)
%PORTY Approximate vertical position of a port on a block.

if portCount <= 0
    y = mean(topBottom);
else
    y = topBottom(1) + (topBottom(2) - topBottom(1)) * portIndex / (portCount + 1);
end
end

function [order, spacedYs] = spacedOrder(desiredY, minGap)
%SPACEDORDER Sort desired Y positions top-to-bottom and enforce spacing.

[spacedYs, order] = sort(desiredY(:));
for position = 2:numel(spacedYs)
    if spacedYs(position) < spacedYs(position - 1) + minGap
        spacedYs(position) = spacedYs(position - 1) + minGap;
    end
end
end

function s = safeName(s)
%SAFENAME Readable MATLAB-valid signal name for blocks and tags.
%
% Invalid characters (spaces, asterisks, dots, ...) become a single
% '_', runs of '_' are collapsed and leading '_'s are dropped, so a
% signal like 'speed*3' becomes 'speed_3' instead of the hex soup
% matlab.lang.makeValidName produces by default ('speed_0x2A_3').

s = char(matlab.lang.makeValidName(s, 'ReplacementStyle', 'underscore'));
s = regexprep(s, '_+', '_');
s = regexprep(s, '^_+', '');
if isempty(s)
    s = 'signal';
end
end

function tf = isSelfFeeding(modelOutputKeys, modelIndex, key)
%ISSELFFEEDING True when this model also PRODUCES the signal it consumes.

tf = any(strcmp(modelOutputKeys{modelIndex}, key));
end

function options = fillDefaults(options, defaults)
%FILLDEFAULTS Fill missing fields of options from a defaults struct.

if isempty(options)
    options = struct();
end
fields = fieldnames(defaults);
for index = 1:numel(fields)
    if ~isfield(options, fields{index})
        options.(fields{index}) = defaults.(fields{index});
    end
end
end

function colorString = paletteColor(index)
%PALETTECOLOR Pleasant, distinguishable background color for a model.
%Colors cycle when there are more models than palette entries.

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
%ERRORCHAINTEXT Error message plus every underlying cause message.
%Simulink load failures report "Error due to multiple causes." with the
%real reason hidden in the cause chain - this flattens it to plain text.

text = strtrim(char(err.message));
if isempty(text)
    text = '(no message)';
end
for groupIndex = 1:numel(err.cause)
    causeGroup = err.cause{groupIndex};
    for causeIndex = 1:numel(causeGroup)
        causeText = strtrim(char(causeGroup(causeIndex).message));
        if ~isempty(causeText)
            text = [text newline '   ' causeText]; %#ok<AGROW>
        end
    end
end
% Simulink messages contain clickable hyperlinks like
% <a href="matlab:...">name</a> - keep only the visible text.
text = regexprep(text, '<a[^>]*>\s*([^<]*?)\s*</a>', '$1');
end