function report = validateModelCompatibility(modelsFolder, selectedModels, progressFcn)
%VALIDATEMODELCOMPATIBILITY Detect sample-time and model-referencing issues
%before generating a parent model.
%
%   report = validateModelCompatibility(modelsFolder, selectedModels)
%   report = validateModelCompatibility(modelsFolder, selectedModels, progressFcn)
%
% INPUTS:
%   modelsFolder   - Folder containing the .slx/.mdl child models
%   selectedModels - Cell array of model names (order does not matter here)
%   progressFcn    - (optional) @(fraction, message) for progress updates
%
% OUTPUT:
%   report - Struct with fields:
%       .Issues          - Array of issue structs (empty = all clear)
%       .ModelsChecked   - Number of models successfully validated
%       .ModelsSkipped   - Number of models that could not be loaded
%       .RecommendedStep - Suggested parent fixed-step size (or 'variable')
%       .Summary         - Human-readable summary string

    if nargin < 3 || isempty(progressFcn)
        progressFcn = @(pct, msg) fprintf('[%.0f%%] %s\n', pct * 100, msg);
    end
    if ischar(selectedModels)
        selectedModels = {selectedModels};
    end

    report = struct( ...
        'Issues',          struct('Category', {}, 'Severity', {}, ...
                              'Model', {}, 'Port', {}, ...
                              'Description', {}, 'FixSuggestion', {}), ...
        'ModelsChecked',   0, ...
        'ModelsSkipped',   0, ...
        'RecommendedStep', '0.01', ...
        'Summary',         '');

    numModels = numel(selectedModels);
    if numModels == 0
        report.Summary = 'No models to validate.';
        return;
    end

    % --- Step 1: Load all child models ------------------------------------
    progressFcn(0.05, 'Loading child models...');
    openedByUs = {};
    loadedModels = {};

    for i = 1:numModels
        modelName = selectedModels{i};
        try
            if ~bdIsLoaded(modelName)
                modelFile = findModelFile(modelsFolder, modelName);
                if isempty(modelFile)
                    report.ModelsSkipped = report.ModelsSkipped + 1;
                    continue;
                end
                load_system(modelFile);
                openedByUs{end + 1} = modelName; %#ok<AGROW>
            end
            loadedModels{end + 1} = modelName; %#ok<AGROW>
        catch loadErr
            report.ModelsSkipped = report.ModelsSkipped + 1;
            report.Issues(end + 1) = makeIssue('LoadError', 'error', ...
                modelName, '', ...
                sprintf('Could not load model: %s', loadErr.message), ...
                'Check that the .slx file exists and is not corrupted.'); %#ok<AGROW>
        end
    end

    report.ModelsChecked = numel(loadedModels);
    if isempty(loadedModels)
        report.Summary = 'No models could be loaded. Check the models folder.';
        return;
    end

    % --- Step 2: Quick standalone sample-time scan ------------------------
    progressFcn(0.20, 'Scanning child model sample times...');
    allSampleTimes = [];

    for i = 1:numel(loadedModels)
        modelName = loadedModels{i};
        try
            % Read the model's fundamental sample time
            modelST = strtrim(get_param(modelName, 'FixedStep'));
            if ~isempty(modelST) && ~strcmpi(modelST, 'auto')
                stVal = str2double(modelST);
                if ~isnan(stVal) && stVal > 0 && ~isinf(stVal)
                    allSampleTimes(end + 1) = stVal; %#ok<AGROW>
                end
            end

            % Check root-level Outport sample times
            outports = find_system(modelName, 'SearchDepth', 1, ...
                'BlockType', 'Outport');
            for j = 1:numel(outports)
                opST = strtrim(get_param(outports{j}, 'SampleTime'));
                if ~isempty(opST) && ~strcmpi(opST, '-1') && ...
                        ~strcmpi(opST, 'inf')
                    stVal = str2double(opST);
                    if ~isnan(stVal) && stVal > 0 && ~isinf(stVal)
                        allSampleTimes(end + 1) = stVal; %#ok<AGROW>
                    end
                end
            end
        catch
            % Skip models that cannot be queried
        end
        progressFcn(0.20 + 0.15 * (i / numel(loadedModels)), ...
            sprintf('Scanning: %s (%d/%d)', modelName, i, numel(loadedModels)));
    end

    % Compute recommended step size (GCD of all detected sample times)
    if ~isempty(allSampleTimes)
        uniqueST = unique(allSampleTimes);
        if numel(uniqueST) == 1
            report.RecommendedStep = num2str(uniqueST(1));
        else
            gcdVal = uniqueST(1);
            for k = 2:numel(uniqueST)
                gcdVal = computeGCD(gcdVal, uniqueST(k));
            end
            report.RecommendedStep = num2str(gcdVal);
        end
    end

    % --- Step 3: Compile a temporary parent to catch real diagnostics -----
    progressFcn(0.40, 'Building temporary validation parent...');
    tempParent = 'teamtools_validation_temp';
    try
        if bdIsLoaded(tempParent)
            close_system(tempParent, 0);
        end
    catch
    end

    try
        new_system(tempParent);
        open_system(tempParent);

        % Match the solver settings that buildParentModelCore uses
        set_param(tempParent, 'SolverType', 'Fixed-step', ...
            'Solver', 'FixedStepDiscrete', ...
            'FixedStep', '0.01');

        % Relax diagnostics so compilation continues past the first error
        try set_param(tempParent, 'InvalidRootInportOutportConnection', 'warning'); catch, end
        try set_param(tempParent, 'ModelReferenceCSMismatchMessage', 'warning'); catch, end
        try set_param(tempParent, 'MultiTaskDSMLog', 'warning'); catch, end
        try set_param(tempParent, 'MultiTaskCondExecSys', 'warning'); catch, end

        % Add Model Reference blocks
        yPos = 50;
        for i = 1:numel(loadedModels)
            modelName = loadedModels{i};
            blockName = sprintf('Ref_%s', matlab.lang.makeValidName(modelName));
            blockPath = [tempParent '/' blockName];
            try
                add_block('simulink/Ports & Subsystems/Model', blockPath, ...
                    'ModelName', modelName, ...
                    'Position', [100, yPos, 300, yPos + 80]);
                yPos = yPos + 130;
            catch
                % Skip models that cannot be referenced
            end
            progressFcn(0.40 + 0.20 * (i / numel(loadedModels)), ...
                sprintf('Referencing: %s (%d/%d)', modelName, i, numel(loadedModels)));
        end

        % --- Step 4: Compile and capture errors ---------------------------
        progressFcn(0.65, 'Compiling to detect sample-time conflicts...');

        warnState = warning('query');
        warning('error', 'Simulink:Engine:*');
        warning('error', 'Simulink:blocks:*');

        compileErrors = {};
        try
            set_param(tempParent, 'SimulationCommand', 'update');
        catch compileErr
            compileErrors{end + 1} = compileErr.message; %#ok<AGROW>
            for gIdx = 1:numel(compileErr.cause)
                causeGroup = compileErr.cause{gIdx};
                for cIdx = 1:numel(causeGroup)
                    if ~isempty(causeGroup(cIdx).message)
                        compileErrors{end + 1} = causeGroup(cIdx).message; %#ok<AGROW>
                    end
                end
            end
        end

        warning(warnState);

        % --- Step 5: Parse errors into actionable issues ------------------
        progressFcn(0.80, 'Analyzing diagnostics...');

        for errIdx = 1:numel(compileErrors)
            errMsg = compileErrors{errIdx};
            errMsg = regexprep(errMsg, '<a[^>]*>\s*([^<]*?)\s*</a>', '$1');

            % Pattern 1: Fixed-step size incompatibility
            if contains(errMsg, 'fixed-step size') || ...
               (contains(errMsg, 'sample time') && contains(errMsg, 'integer multiple'))

                detectedModel = extractModelName(errMsg, loadedModels);
                report.Issues(end + 1) = makeIssue('SampleTime', 'error', ...
                    detectedModel, '', ...
                    sprintf('Fixed-step size (0.01) is incompatible with sample times in "%s".', detectedModel), ...
                    sprintf(['Option A: Change the parent model FixedStep to %s after generation.\n', ...
                             'Option B: Adjust sample times in "%s" to be multiples of 0.01.\n', ...
                             'Option C: Use a variable-step solver in the parent model.'], ...
                        report.RecommendedStep, detectedModel)); %#ok<AGROW>
            end

            % Pattern 2: Root Outport connection issues
            if contains(errMsg, 'Invalid root Outport') || ...
               (contains(errMsg, 'Root Outport') && contains(errMsg, 'constant'))

                detectedModel = extractModelName(errMsg, loadedModels);
                portMatch = regexp(errMsg, 'Root Outport (\d+)', 'tokens', 'once');
                portInfo = '';
                if ~isempty(portMatch)
                    portInfo = sprintf(' (Outport %s)', portMatch{1});
                end
                report.Issues(end + 1) = makeIssue('OutportConnection', 'error', ...
                    detectedModel, portInfo, ...
                    sprintf('Root Outport%s in "%s" has a sample-time conflict.', portInfo, detectedModel), ...
                    sprintf('Set the Outport block SampleTime to "inf" (constant) in "%s".', detectedModel)); %#ok<AGROW>
            end

            % Pattern 3: Sample time mismatch between models
            if contains(errMsg, 'sample time') && contains(errMsg, 'mismatch')
                detectedModel = extractModelName(errMsg, loadedModels);
                report.Issues(end + 1) = makeIssue('SampleTimeMismatch', 'warning', ...
                    detectedModel, '', ...
                    sprintf('Sample time mismatch involving "%s": %s', detectedModel, errMsg), ...
                    'Ensure all interconnected models share compatible sample rates.'); %#ok<AGROW>
            end

            % Pattern 4: Data dictionary shadowing
            if contains(errMsg, 'shadowed') && contains(errMsg, 'dictionary')
                report.Issues(end + 1) = makeIssue('DataDictionary', 'warning', ...
                    '', '', ...
                    sprintf('Data dictionary conflict: %s', errMsg), ...
                    'Run Simulink.data.dictionary.closeAll before generating.'); %#ok<AGROW>
            end
        end

    catch setupErr
        report.Issues(end + 1) = makeIssue('ValidationError', 'error', ...
            '', '', ...
            sprintf('Validation setup failed: %s', setupErr.message), ...
            'Check that Simulink is properly licensed and models are valid.'); %#ok<AGROW>
    end

    % --- Step 6: Clean up -------------------------------------------------
    progressFcn(0.95, 'Cleaning up...');
    try
        close_system(tempParent, 0);
    catch
    end
    for i = 1:numel(openedByUs)
        try close_system(openedByUs{i}, 0); catch, end
    end

    % --- Build summary ----------------------------------------------------
    errorCount = sum(strcmp({report.Issues.Severity}, 'error'));
    warnCount = sum(strcmp({report.Issues.Severity}, 'warning'));

    if isempty(report.Issues)
        report.Summary = sprintf('All %d models are compatible. Ready to generate.', ...
            report.ModelsChecked);
    else
        report.Summary = sprintf('%d error(s), %d warning(s) found across %d models.', ...
            errorCount, warnCount, report.ModelsChecked);
        if errorCount > 0
            report.Summary = [report.Summary, ...
                sprintf('\nRecommended parent FixedStep: %s', report.RecommendedStep)];
        end
    end

    progressFcn(1.0, report.Summary);
end

%% ========================================================================
%%  HELPERS
%% ========================================================================
function issue = makeIssue(category, severity, model, port, description, fix)
    issue = struct( ...
        'Category',      category, ...
        'Severity',      severity, ...
        'Model',         model, ...
        'Port',          port, ...
        'Description',   description, ...
        'FixSuggestion', fix);
end

function modelName = extractModelName(errMsg, knownModels)
    modelName = '(unknown)';
    tokens = regexp(errMsg, '''([^'']+)''', 'tokens');
    for tIdx = 1:numel(tokens)
        candidate = tokens{tIdx}{1};
        if any(strcmpi(knownModels, candidate))
            modelName = candidate;
            return;
        end
    end
    % Fallback: try to find any known model name in the message
    for mIdx = 1:numel(knownModels)
        if contains(errMsg, knownModels{mIdx})
            modelName = knownModels{mIdx};
            return;
        end
    end
end

function modelFile = findModelFile(modelsFolder, modelName)
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

function g = computeGCD(a, b)
%COMPUTEGCD Greatest common divisor for floating-point sample times.
% Uses a tolerance-based approach since sample times are rarely exact integers.
    tol = 1e-9;
    a = abs(a);
    b = abs(b);
    if a < tol
        g = b;
        return;
    end
    if b < tol
        g = a;
        return;
    end
    % Scale to integers to avoid floating-point drift
    scale = 1e6;
    aInt = round(a * scale);
    bInt = round(b * scale);
    gInt = gcd(aInt, bInt);
    g = gInt / scale;
end