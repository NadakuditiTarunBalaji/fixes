function issues = validateModels(modelsFolder, selectedModels, progressFcn)
%VALIDATEMODELS Pre-build validation for sample time and SLDD conflicts.
%
%   issues = validateModels(modelsFolder, selectedModels)
%   issues = validateModels(modelsFolder, selectedModels, progressFcn)
%
%   Returns a struct array:
%     issues(i).Category    — 'SampleTime' | 'SLDD' | 'Config' | 'Info'
%     issues(i).Severity    — 'error' | 'warning' | 'info'
%     issues(i).Model       — Model name or symbol name
%     issues(i).Port        — Port name (SampleTime only, else '')
%     issues(i).Description — Human-readable description
%     issues(i).FixMethod   — 'InsertUnitDelay' | 'SetOutportConstant' |
%                             'SyncToMaster' | 'MatchParent' | 'none'
%     issues(i).FixData     — Struct with data needed to apply the fix

    if nargin < 3 || isempty(progressFcn)
        progressFcn = @(pct, msg) fprintf('[%.0f%%] %s\n', pct*100, msg);
    end

    issues = struct('Category', {}, 'Severity', {}, 'Model', {}, ...
                    'Port', {}, 'Description', {}, 'FixMethod', {}, 'FixData', {});

    if ischar(selectedModels), selectedModels = {selectedModels}; end
    selectedModels = regexprep(selectedModels, '\.(slx|mdl)$', '', 'ignorecase');
    numModels = numel(selectedModels);

    % ================================================================
    % CHECK 1: SAMPLE TIME MISMATCHES
    % ================================================================
    progressFcn(0.1, sprintf('Checking sample times in %d models...', numModels));

    for i = 1:numModels
        modelName = selectedModels{i};
        progressFcn(0.1 + 0.4 * (i/numModels), sprintf('Sample time: %s (%d/%d)', modelName, i, numModels));

        openedByUs = false;
        try
            if ~bdIsLoaded(modelName)
                % Try to find and load the model
                modelFile = findModelFile(modelsFolder, modelName);
                if isempty(modelFile), continue; end
                load_system(modelFile);
                openedByUs = true;
            end

            % Find root Outports
            outports = find_system(modelName, 'SearchDepth', 1, ...
                'FollowLinks', 'on', 'LookUnderMasks', 'all', 'BlockType', 'Outport');
            if isempty(outports), continue; end
            if ~iscell(outports), outports = num2cell(outports); end
            outports = outports(:);

            for j = 1:numel(outports)
                outportPath = outports{j};
                outportName = get_param(outportPath, 'Name');

                % Get the sample time of the signal driving this Outport
                try
                    % Get the line connected to the Inport side of the Outport block
                    portHandles = get_param(outportPath, 'PortHandles');
                    inportHandle = portHandles.Inport;
                    if isempty(inportHandle), continue; end

                    lineHandle = get_param(inportHandle, 'LineHandle');
                    if isempty(lineHandle) || lineHandle == -1, continue; end

                    % Get the source block of this line
                    srcPortHandle = get_param(lineHandle, 'SrcPortHandle');
                    if isempty(srcPortHandle) || srcPortHandle == -1, continue; end

                    srcBlockPath = get_param(srcPortHandle, 'Parent');
                    srcBlockType = get_param(srcBlockPath, 'BlockType');

                    % Check if the driving block is a Constant
                    isConstantDriver = strcmp(srcBlockType, 'Constant') || ...
                                       strcmp(srcBlockType, 'Ground');

                    if isConstantDriver
                        % Check if the Outport expects non-constant sample time
                        outportST = get_param(outportPath, 'SampleTime');
                        if isempty(outportST) || strcmp(outportST, '-1')
                            % Inherited — will inherit from parent, likely discrete
                            issues(end+1) = struct( ...
                                'Category', 'SampleTime', ...
                                'Severity', 'error', ...
                                'Model', modelName, ...
                                'Port', outportName, ...
                                'Description', sprintf(...
                                    'Outport "%s" in model "%s" is driven by a %s block (constant sample time). ' + ...
                                    'When referenced from a discrete parent, this causes a sample time mismatch.', ...
                                    outportName, modelName, srcBlockType), ...
                                'FixMethod', 'InsertUnitDelay', ...
                                'FixData', struct( ...
                                    'ModelName', modelName, ...
                                    'OutportPath', outportPath, ...
                                    'DriverBlockPath', srcBlockPath, ...
                                    'DriverType', srcBlockType));
                        end
                    end
                catch
                    % If we cannot trace the signal, skip this port
                end
            end

            if openedByUs
                close_system(modelName, 0);
            end
        catch
            if openedByUs
                try close_system(modelName, 0); catch, end
            end
            issues(end+1) = struct( ...
                'Category', 'Info', 'Severity', 'warning', ...
                'Model', modelName, 'Port', '', ...
                'Description', sprintf('Could not fully analyze model "%s".', modelName), ...
                'FixMethod', 'none', 'FixData', struct());
        end
    end

    % ================================================================
    % CHECK 2: SLDD CONFLICTS
    % ================================================================
    progressFcn(0.6, 'Scanning for SLDD files...');

    slddFiles = dir(fullfile(modelsFolder, '**', '*.sldd'));

    if isempty(slddFiles)
        issues(end+1) = struct( ...
            'Category', 'Info', 'Severity', 'info', ...
            'Model', 'N/A', 'Port', '', ...
            'Description', 'No .sldd files found in the models folder. SLDD conflict check skipped.', ...
            'FixMethod', 'none', 'FixData', struct());
    else
        progressFcn(0.65, sprintf('Checking %d SLDD files for conflicts...', numel(slddFiles)));
        slddIssues = checkSLDDConflicts(slddFiles, progressFcn);
        issues = [issues; slddIssues];
    end

    % ================================================================
    % SUMMARY
    % ================================================================
    nErrors = sum(strcmp({issues.Severity}, 'error'));
    nWarnings = sum(strcmp({issues.Severity}, 'warning'));
    nInfo = sum(strcmp({issues.Severity}, 'info'));

    progressFcn(1.0, sprintf('Validation complete: %d errors, %d warnings, %d info', ...
        nErrors, nWarnings, nInfo));
end

% =====================================================================
% Helper: Find model file
% =====================================================================
function modelFile = findModelFile(modelsFolder, modelName)
    modelFile = '';
    candidates = dir(fullfile(modelsFolder, '**', [modelName '.slx']));
    if isempty(candidates)
        candidates = dir(fullfile(modelsFolder, '**', [modelName '.mdl']));
    end
    if ~isempty(candidates)
        modelFile = fullfile(candidates(1).folder, candidates(1).name);
    end
end

% =====================================================================
% Helper: Check SLDD Conflicts
% =====================================================================
function slddIssues = checkSLDDConflicts(slddFiles, progressFcn)
    slddIssues = struct('Category', {}, 'Severity', {}, 'Model', {}, ...
                        'Port', {}, 'Description', {}, 'FixMethod', {}, 'FixData', {});

    % Collect all symbol definitions
    allDefs = containers.Map('KeyType', 'char', 'ValueType', 'any');

    for i = 1:numel(slddFiles)
        dictPath = fullfile(slddFiles(i).folder, slddFiles(i).name);
        dictName = slddFiles(i).name;
        progressFcn(0.65 + 0.25 * (i/numel(slddFiles)), ...
            sprintf('Scanning dictionary: %s', dictName));

        try
            dictObj = Simulink.data.dictionary.open(dictPath);
            dSect = getSection(dictObj, 'Design Data');
            entries = find(dSect, '');

            for j = 1:numel(entries)
                try
                    entryObj = entries{j};
                    symName = entryObj.Name;
                    symValue = getValue(entryObj);

                    % Check if this is a Signal or Parameter with Min/Max
                    hasMinMax = false;
                    symMin = []; symMax = [];
                    if isobject(symValue)
                        if isprop(symValue, 'Min') && isprop(symValue, 'Max')
                            symMin = symValue.Min;
                            symMax = symValue.Max;
                            hasMinMax = true;
                        end
                    elseif isstruct(symValue)
                        if isfield(symValue, 'Min') && isfield(symValue, 'Max')
                            symMin = symValue.Min;
                            symMax = symValue.Max;
                            hasMinMax = true;
                        end
                    end

                    if hasMinMax
                        def = struct('DictPath', dictPath, 'DictName', dictName, ...
                                     'Min', symMin, 'Max', symMax);
                        if isKey(allDefs, symName)
                            existing = allDefs(symName);
                            allDefs(symName) = [existing; def];
                        else
                            allDefs(symName) = def;
                        end
                    end
                catch
                    % Skip entries that cannot be read
                end
            end
            close(dictObj);
        catch
            % Skip dictionaries that cannot be opened
        end
    end

    % Find conflicts
    symNames = keys(allDefs);
    for i = 1:numel(symNames)
        symName = symNames{i};
        defs = allDefs(symName);
        if numel(defs) < 2, continue; end

        % Compare Min values
        minsMatch = true;
        for k = 2:numel(defs)
            if ~isequal(defs(k).Min, defs(1).Min)
                minsMatch = false; break;
            end
        end

        % Compare Max values
        maxsMatch = true;
        for k = 2:numel(defs)
            if ~isequal(defs(k).Max, defs(1).Max)
                maxsMatch = false; break;
            end
        end

        if ~minsMatch || ~maxsMatch
            % Find the master definition (the one with explicit non-empty values)
            masterIdx = 1;
            for k = 1:numel(defs)
                if ~isempty(defs(k).Min) && ~isempty(defs(k).Max)
                    masterIdx = k; break;
                end
            end

            dictNames = {defs.DictName};
            slddIssues(end+1) = struct( ...
                'Category', 'SLDD', ...
                'Severity', 'error', ...
                'Model', symName, ...
                'Port', '', ...
                'Description', sprintf(...
                    'Symbol "%s" has %d inconsistent definitions across: %s. ' + ...
                    'Master: %s (Min=%s, Max=%s)', ...
                    symName, numel(defs), strjoin(dictNames, ', '), ...
                    defs(masterIdx).DictName, ...
                    mat2str(defs(masterIdx).Min), mat2str(defs(masterIdx).Max)), ...
                'FixMethod', 'SyncToMaster', ...
                'FixData', struct( ...
                    'Symbol', symName, ...
                    'Definitions', defs, ...
                    'MasterIndex', masterIdx));
        end
    end
end