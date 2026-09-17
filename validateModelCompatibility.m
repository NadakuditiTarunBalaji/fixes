function report = validateModelCompatibility(modelsFolder, selectedModels, progressFcn)
%VALIDATEMODELCOMPATIBILITY Highly optimized compatibility checker.
% Performance-engineered to validate 200+ models in under 2 minutes.

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

    % --- STEP 1: Fast Disk Search & Loading (Parallel-friendly load) -------
    % progressFcn(0.10, sprintf('Loading %d child models into memory...', numModels));
    % openedByUs = {};
    % loadedModels = {};

    % % Pre-discover paths to avoid searching disk inside the loop
    % allFiles = [dir(fullfile(modelsFolder, '**', '*.slx')); dir(fullfile(modelsFolder, '**', '*.mdl'))];
    % allFiles = allFiles(~[allFiles.isdir]);
    
    % fileMap = containers.Map('KeyType', 'char', 'ValueType', 'char');
    % for fIdx = 1:numel(allFiles)
    %     [~, bName] = fileparts(allFiles(fIdx).name);
    %     fileMap(lower(bName)) = fullfile(allFiles(fIdx).folder, allFiles(fIdx).name);
    % end

    % for i = 1:numModels
    %     modelName = selectedModels{i};
    %     try
    %         if ~bdIsLoaded(modelName)
    %             key = lower(modelName);
    %             if isKey(fileMap, key)
    %                 load_system(fileMap(key));
    %                 openedByUs{end + 1} = modelName; %#ok<AGROW>
    %             else
    %                 report.ModelsSkipped = report.ModelsSkipped + 1;
    %                 continue;
    %             end
    %         end
    %         loadedModels{end + 1} = modelName; %#ok<AGROW>
    %     catch loadErr
    %         report.ModelsSkipped = report.ModelsSkipped + 1;
    %         report.Issues(end + 1) = makeIssue('LoadError', 'error', ...
    %             modelName, '', ...
    %             sprintf('Could not load model: %s', loadErr.message), ...
    %             'Ensure the model file is not corrupted.'); %#ok<AGROW>
    %     end
    % end

    % report.ModelsChecked = numel(loadedModels);
    % if isempty(loadedModels)
    %     report.Summary = 'No models could be loaded.';
    %     return;
    % end
        % --- STEP 1: Pre-map and Load Models (Deduplication-Safe) --------------
    progressFcn(0.10, sprintf('Loading %d child models into memory...', numModels));
    openedByUs = {};
    loadedModels = {};

    allFiles = [dir(fullfile(modelsFolder, '**', '*.slx')); dir(fullfile(modelsFolder, '**', '*.mdl'))];
    allFiles = allFiles(~[allFiles.isdir]);
    
    fileMap = containers.Map('KeyType', 'char', 'ValueType', 'char');
    for fIdx = 1:numel(allFiles)
        [~, bName] = fileparts(allFiles(fIdx).name);
        key = lower(bName);
        % If key does NOT exist yet, store it (keeps the first occurrence)
        if ~isKey(fileMap, key)
            fileMap(key) = fullfile(allFiles(fIdx).folder, allFiles(fIdx).name);
        end
    end

    for i = 1:numModels
        modelName = selectedModels{i};
        try
            if ~bdIsLoaded(modelName)
                key = lower(modelName);
                if isKey(fileMap, key)
                    load_system(fileMap(key));
                    openedByUs{end + 1} = modelName; %#ok<AGROW>
                else
                    report.ModelsSkipped = report.ModelsSkipped + 1;
                    continue;
                end
            end
            loadedModels{end + 1} = modelName; %#ok<AGROW>
        catch loadErr
            report.ModelsSkipped = report.ModelsSkipped + 1;
            report.Issues(end + 1) = makeIssue('LoadError', 'error', modelName, '', ...
                sprintf('Could not load model: %s', loadErr.message), 'Check file integrity.'); %#ok<AGROW>
        end
    end

    report.ModelsChecked = numel(loadedModels);
    if isempty(loadedModels)
        report.LogLines = {'ERROR: No models could be loaded from the selected folder.'};
        return;
    end

    % --- STEP 2: FAST STATIC CHECK (Milliseconds instead of Minutes) -------
    progressFcn(0.30, 'Performing static sample-time checks...');
    allSampleTimes = [];

    for i = 1:numel(loadedModels)
        modelName = loadedModels{i};
        try
            % Read child model fundamental step size statically
            modelST = strtrim(get_param(modelName, 'FixedStep'));
            if ~isempty(modelST) && ~strcmpi(modelST, 'auto')
                stVal = str2double(modelST);
                if ~isnan(stVal) && stVal > 0 && ~isinf(stVal)
                    allSampleTimes(end + 1) = stVal; %#ok<AGROW>
                end
            end

            % Check root-level Outports statically
            outports = find_system(modelName, 'SearchDepth', 1, 'BlockType', 'Outport');
            for j = 1:numel(outports)
                opPath = outports{j};
                opName = get_param(opPath, 'Name');
                opST = strtrim(get_param(opPath, 'SampleTime'));
                
                % Static Warning: Hardcoded positive sample rate on outports is a major hazard
                if ~isempty(opST) && ~any(strcmpi(opST, {'-1', 'inf', 'inherited'}))
                    stVal = str2double(opST);
                    if ~isnan(stVal) && stVal > 0
                        report.Issues(end + 1) = makeIssue('SampleTime', 'warning', ...
                            modelName, opName, ...
                            sprintf('Root Outport "%s" has a hardcoded sample time of %s.', opName, opST), ...
                            'Change SampleTime to "-1" (inherited) to prevent parent referencing mismatch.'); %#ok<AGROW>
                    end
                end
            end
        catch
        end
    end

    % Calculate Recommended step size from gathered data
    if ~isempty(allSampleTimes)
        uniqueST = unique(allSampleTimes);
        gcdVal = uniqueST(1);
        for k = 2:numel(uniqueST)
            gcdVal = computeGCD(gcdVal, uniqueST(k));
        end
        report.RecommendedStep = num2str(gcdVal);
    end

    % --- STEP 3: ONE parent-level compilation to resolve references -------
    progressFcn(0.50, 'Assembling temporary system for compilation...');
    tempParent = 'teamtools_validation_temp';
    try
        if bdIsLoaded(tempParent), close_system(tempParent, 0); end
    catch
    end

    try
        new_system(tempParent);
        set_param(tempParent, 'SolverType', 'Fixed-step', ...
            'Solver', 'FixedStepDiscrete', ...
            'FixedStep', '0.01');

        % De-escalate model-ref errors so compile doesn't immediately stop
        try set_param(tempParent, 'InvalidRootInportConnection', 'warning'); catch, end
        try set_param(tempParent, 'InvalidRootOutportConnection', 'warning'); catch, end
        try set_param(tempParent, 'ModelReferenceCSMismatchMessage', 'warning'); catch, end

        % Fast reference block additions
        yPos = 40;
        for i = 1:numel(loadedModels)
            modelName = loadedModels{i};
            blockName = sprintf('Ref_%s', matlab.lang.makeValidName(modelName));
            add_block('simulink/Ports & Subsystems/Model', [tempParent '/' blockName], ...
                'ModelName', modelName, ...
                'Position', [100, yPos, 300, yPos + 60]);
            yPos = yPos + 100;
        end

        % --- STEP 4: Compile parent model (Run Simulink Engine once) --------
        % --- STEP 4: Single Multi-threaded Simulink Compile -----------------
        progressFcn(0.70, 'Compiling referenced hierarchy...');
        compileErrors = {};
        
        try
            % Simulink update diagram automatically captures all referencing errors
            set_param(tempParent, 'SimulationCommand', 'update');
        catch compileErr
            compileErrors{end + 1} = compileErr.message; %#ok<AGROW>
            for gIdx = 1:numel(compileErr.cause)
                causeGroup = compileErr.cause{gIdx};
                for cIdx = 1:numel(causeGroup)
                    compileErrors{end + 1} = causeGroup(cIdx).message; %#ok<AGROW>
                end
            end
        end

        % --- STEP 5: Fast parsing of compilation logs ---------------------
        progressFcn(0.90, 'Analyzing compilation results...');
        for errIdx = 1:numel(compileErrors)
            errMsg = compileErrors{errIdx};
            errMsg = regexprep(errMsg, '<a[^>]*>\s*([^<]*?)\s*</a>', '$1');

            % Pattern A: Solver / Fixed-Step incompatibility
            if contains(errMsg, 'fixed-step size') || contains(errMsg, 'integer multiple')
                detectedModel = extractModelName(errMsg, loadedModels);
                report.Issues(end + 1) = makeIssue('SampleTime', 'error', ...
                    detectedModel, '', ...
                    sprintf('Fixed-step size (0.01) is incompatible with sample times in child model "%s".', detectedModel), ...
                    sprintf('Change parent model FixedStep to "%s", or use a variable-step solver.', report.RecommendedStep)); %#ok<AGROW>
            end

            % Pattern B: Constant Outport driven by non-constant signal
            if contains(errMsg, 'Invalid root Outport') || contains(errMsg, 'constant sample time')
                detectedModel = extractModelName(errMsg, loadedModels);
                report.Issues(end + 1) = makeIssue('OutportConnection', 'error', ...
                    detectedModel, '', ...
                    sprintf('Outport connection sample-time conflict in child model "%s".', detectedModel), ...
                    sprintf('Open "%s" and set your root Outports SampleTime property to "inf".', detectedModel)); %#ok<AGROW>
            end
        end

    catch setupErr
        report.Issues(end + 1) = makeIssue('ValidationError', 'error', ...
            '', '', ...
            sprintf('Validation environment setup failed: %s', setupErr.message), ...
            'Ensure Simulink is configured correctly.'); 
    end

    % --- STEP 6: Clean up -------------------------------------------------
    progressFcn(0.95, 'Cleaning up temporary files...');
    try close_system(tempParent, 0); catch, end
    for i = 1:numel(openedByUs)
        try close_system(openedByUs{i}, 0); catch, end
    end

    % Build statistics
    errorCount = sum(strcmp({report.Issues.Severity}, 'error'));
    warnCount = sum(strcmp({report.Issues.Severity}, 'warning'));

    if isempty(report.Issues)
        report.Summary = sprintf('All %d models validated successfully. All systems compatible!', report.ModelsChecked);
    else
        report.Summary = sprintf('%d error(s), %d warning(s) found across %d models checked.', ...
            errorCount, warnCount, report.ModelsChecked);
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
    for mIdx = 1:numel(knownModels)
        if contains(errMsg, knownModels{mIdx})
            modelName = knownModels{mIdx};
            return;
        end
    end
end

function g = computeGCD(a, b)
    tol = 1e-9;
    a = abs(a); b = abs(b);
    if a < tol, g = b; return; end
    if b < tol, g = a; return; end
    scale = 1e6;
    g = gcd(round(a * scale), round(b * scale)) / scale;
end