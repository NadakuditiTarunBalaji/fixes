function issues = checkSampleTimes(modelsFolder, selectedModels, progressFcn)
%CHECKSAMPLETIMES Creates a temporary parent model with Model Reference
% blocks for all selected models, compiles it, and captures Simulink's
% actual model-referencing diagnostics (InvalidRootOutportConnection,
% sample time mismatches, etc.).
%
% This is the ONLY reliable way to detect these errors because they are
% Model Referencing diagnostics that only fire in a parent-child context.

if nargin < 3 || isempty(progressFcn)
    progressFcn = @(pct, msg) fprintf('[%.0f%%] %s\n', pct*100, msg);
end
if ischar(selectedModels)
    selectedModels = {selectedModels};
end

issues = struct('Category', {}, 'Severity', {}, 'Model', {}, ...
    'Port', {}, 'Description', {}, 'FixMethod', {}, 'FixData', {});

numModels = numel(selectedModels);
if numModels == 0
    return;
end

% --- Step 1: Load all models ---
progressFcn(0.05, 'Loading models for validation...');
openedByUs = {};
for i = 1:numModels
    modelName = selectedModels{i};
    try
        if ~bdIsLoaded(modelName)
            modelFile = findModelFileOnDisk(modelsFolder, modelName);
            if isempty(modelFile)
                continue;
            end
            load_system(modelFile);
            openedByUs{end + 1} = modelName; %#ok<AGROW>
        end
    catch
    end
end

% --- Step 2: Create a temporary throwaway parent model ---
progressFcn(0.20, 'Building temporary validation parent...');
tempParentName = 'teamtools_validation_temp';
try
    if bdIsLoaded(tempParentName)
        close_system(tempParentName, 0);
    end
catch
end

new_system(tempParentName);
open_system(tempParentName);

% Set solver to fixed-step discrete (matches what Generate does)
set_param(tempParentName, 'SolverType', 'Fixed-step', 'Solver', 'FixedStepDiscrete');

% Relax diagnostics on the temp parent so compilation continues past
% the first error and we can collect ALL issues in one pass
try set_param(tempParentName, 'InvalidRootInportOutportConnection', 'warning'); catch, end
try set_param(tempParentName, 'ModelReferenceCSMismatchMessage', 'warning'); catch, end
try set_param(tempParentName, 'MultiTaskDSMLog', 'warning'); catch, end
try set_param(tempParentName, 'MultiTaskCondExecSys', 'warning'); catch, end

% Add a Model Reference block for each selected model
modelBlockNames = {};
yPos = 50;
for i = 1:numModels
    modelName = selectedModels{i};
    if ~bdIsLoaded(modelName)
        continue;
    end
    blockName = sprintf('Ref_%s', matlab.lang.makeValidName(modelName));
    blockPath = [tempParentName '/' blockName];
    try
        add_block('simulink/Ports & Subsystems/Model', blockPath, ...
            'ModelName', modelName, ...
            'Position', [100, yPos, 300, yPos + 100]);
        modelBlockNames{end + 1} = blockName; %#ok<AGROW>
        yPos = yPos + 150;
    catch
        % Skip models that cannot be referenced
    end
    progressFcn(0.20 + 0.30 * (i / numModels), ...
        sprintf('Inserting model reference: %s (%d/%d)', modelName, i, numModels));
end

% --- Step 3: Compile the temporary parent and capture diagnostics ---
progressFcn(0.55, 'Compiling parent to detect model-referencing issues...');

% Capture the current warning state
warnState = warning('query');

% Turn all Simulink warnings into catchable errors so we can read them
warning('error', 'Simulink:Engine:InvalidRootInportOutportConnection');
warning('error', 'Simulink:Engine:*');
warning('error', 'Simulink:blocks:*');

compileErrors = {};

try
    set_param(tempParentName, 'SimulationCommand', 'update');
catch compileErr
    % The compilation threw an error - extract the message
    compileErrors{end + 1} = compileErr.message; %#ok<AGROW>
    
    % Also check the cause chain for additional errors
    for gIdx = 1:numel(compileErr.cause)
        causeGroup = compileErr.cause{gIdx};
        for cIdx = 1:numel(causeGroup)
            if ~isempty(causeGroup(cIdx).message)
                compileErrors{end + 1} = causeGroup(cIdx).message; %#ok<AGROW>
            end
        end
    end
end

% Restore warning state
warning(warnState);

% --- Step 4: Parse the captured errors into fixable issues ---
progressFcn(0.70, 'Analyzing diagnostics...');

for errIdx = 1:numel(compileErrors)
    errMsg = compileErrors{errIdx};
    
    % Clean hyperlinks from Simulink messages
    errMsg = regexprep(errMsg, '<a[^>]*>\s*([^<]*?)\s*</a>', '$1');
    
    % --- Pattern 1: Invalid root Outport block connection ---
    if contains(errMsg, 'Invalid root Outport block connection') || ...
       (contains(errMsg, 'Root Outport') && contains(errMsg, 'constant sample time'))
        
        % Extract model name from the error message
        modelMatch = regexp(errMsg, '''([^'']+)''', 'tokens');
        detectedModel = '';
        if ~isempty(modelMatch)
            for mIdx = 1:numel(modelMatch)
                candidate = modelMatch{mIdx}{1};
                if any(strcmpi(selectedModels, candidate))
                    detectedModel = candidate;
                    break;
                end
            end
        end
        
        % Extract Outport number
        portMatch = regexp(errMsg, 'Root Outport (\d+)', 'tokens', 'once');
        portNum = '';
        if ~isempty(portMatch)
            portNum = portMatch{1};
        end
        
        if ~isempty(detectedModel) && bdIsLoaded(detectedModel)
            % Find the actual Outport block
            outportPath = '';
            outportName = '';
            try
                if ~isempty(portNum)
                    matches = find_system(detectedModel, 'SearchDepth', 1, ...
                        'BlockType', 'Outport', 'Port', portNum);
                    if ~isempty(matches)
                        outportPath = matches{1};
                        outportName = get_param(outportPath, 'Name');
                    end
                end
                if isempty(outportPath)
                    allOutports = find_system(detectedModel, 'SearchDepth', 1, ...
                        'BlockType', 'Outport');
                    if ~isempty(allOutports)
                        outportPath = allOutports{1};
                        outportName = get_param(outportPath, 'Name');
                    end
                end
            catch
            end
            
            if ~isempty(outportPath)
                issues(end + 1) = struct( ... %#ok<AGROW>
                    'Category', 'SampleTime', ...
                    'Severity', 'error', ...
                    'Model', detectedModel, ...
                    'Port', outportName, ...
                    'Description', sprintf(['Simulink diagnostic: Root Outport "%s" ' ...
                        'in model "%s" does not have a constant sample time but is ' ...
                        'driven by a constant signal. Fix: set SampleTime to Inf.'], ...
                        outportName, detectedModel), ...
                    'FixMethod', 'SetOutportConstant', ...
                    'FixData', struct( ...
                        'ModelName', detectedModel, ...
                        'OutportPath', outportPath));
            end
        end
    end
    
    % --- Pattern 2: Sample time mismatch ---
    if contains(errMsg, 'sample time') && contains(errMsg, 'mismatch')
        modelMatch = regexp(errMsg, '''([^'']+)''', 'tokens');
        detectedModel = '';
        if ~isempty(modelMatch)
            for mIdx = 1:numel(modelMatch)
                candidate = modelMatch{mIdx}{1};
                if any(strcmpi(selectedModels, candidate))
                    detectedModel = candidate;
                    break;
                end
            end
        end
        if ~isempty(detectedModel)
            issues(end + 1) = struct( ... %#ok<AGROW>
                'Category', 'SampleTime', ...
                'Severity', 'warning', ...
                'Model', detectedModel, ...
                'Port', '', ...
                'Description', sprintf('Sample time mismatch in "%s": %s', ...
                    detectedModel, errMsg), ...
                'FixMethod', 'none', ...
                'FixData', struct());
        end
    end
end

% --- Step 5: Also check compiled sample times directly ---
progressFcn(0.80, 'Checking compiled sample times on root Outports...');

for i = 1:numModels
    modelName = selectedModels{i};
    if ~bdIsLoaded(modelName)
        continue;
    end
    
    % Skip if we already found issues for this model
    alreadyFlagged = any(strcmp({issues.Model}, modelName) & ...
        strcmp({issues.Category}, 'SampleTime'));
    if alreadyFlagged
        continue;
    end
    
    try
        % Compile the model standalone to resolve inherited sample times
        eval([modelName '([],[],[],''compile'');']);
        
        outports = find_system(modelName, 'SearchDepth', 1, ...
            'BlockType', 'Outport');
        
        for j = 1:numel(outports)
            op = outports{j};
            opName = get_param(op, 'Name');
            opST = strtrim(get_param(op, 'SampleTime'));
            
            % Skip if already explicitly constant
            if strcmpi(opST, 'inf')
                continue;
            end
            
            try
                pH = get_param(op, 'PortHandles');
                inHandle = pH.Inport;
                if isempty(inHandle) || inHandle == -1
                    continue;
                end
                
                compiledST = get_param(inHandle, 'CompiledSampleTime');
                
                % Check if the compiled sample time is constant [Inf, 0]
                if isnumeric(compiledST) && numel(compiledST) >= 1 && ...
                        isinf(compiledST(1)) && compiledST(1) > 0
                    
                    issues(end + 1) = struct( ... %#ok<AGROW>
                        'Category', 'SampleTime', ...
                        'Severity', 'error', ...
                        'Model', modelName, ...
                        'Port', opName, ...
                        'Description', sprintf(['Root Outport "%s" in model "%s" ' ...
                            'has SampleTime="%s" but compiled signal rate is ' ...
                            'Constant (Inf). This will cause a build failure ' ...
                            'when referenced from a parent model.'], ...
                            opName, modelName, opST), ...
                        'FixMethod', 'SetOutportConstant', ...
                        'FixData', struct( ...
                            'ModelName', modelName, ...
                            'OutportPath', op));
                end
            catch
            end
        end
        
        eval([modelName '([],[],[],''term'');']);
    catch
        try eval([modelName '([],[],[],''term'');']); catch, end
    end
end

% --- Step 6: Clean up the temporary parent model ---
progressFcn(0.95, 'Cleaning up...');
try
    close_system(tempParentName, 0);
catch
end

% Close models we opened
for i = 1:numel(openedByUs)
    try close_system(openedByUs{i}, 0); catch, end
end

progressFcn(1, sprintf('Validation complete: %d issue(s) found.', numel(issues)));
end

% =========================================================================
%  HELPER
% =========================================================================
function modelFile = findModelFileOnDisk(modelsFolder, modelName)
modelFile = '';
candidates = dir(fullfile(modelsFolder, '**', [modelName '.slx']));
if isempty(candidates)
    candidates = dir(fullfile(modelsFolder, '**', [modelName '.mdl']));
end
candidates = candidates(~[candidates.isdir]);
if ~isempty(candidates)
    modelFile = fullfile(candidates(1).folder, candidates(1).name);
end
end