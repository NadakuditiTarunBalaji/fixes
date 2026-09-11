function issues = checkSampleTimes(modelsFolder, selectedModels, progressFcn)
%CHECKSAMPLETIMES Scans child models for compiled sample time mismatches.
% Uses a dual-engine (deep recursive static trace + compiled diagnostics capture)
% to catch errors before they cause the parent model build to crash.

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

for i = 1:numModels
    modelName = selectedModels{i};
    progressFcn((i - 1) / numModels, sprintf('Sample time: %s (%d/%d)', ...
        modelName, i, numModels));

    openedByUs = false;
    try
        if ~bdIsLoaded(modelName)
            modelFile = findModelFileOnDisk(modelsFolder, modelName);
            if isempty(modelFile)
                issues(end + 1) = struct( ... %#ok<AGROW>
                    'Category', 'Info', 'Severity', 'warning', ...
                    'Model', modelName, 'Port', '', ...
                    'Description', sprintf('Model file not found for "%s".', modelName), ...
                    'FixMethod', 'none', 'FixData', struct());
                continue;
            end
            load_system(modelFile);
            openedByUs = true;
        end

        outportPaths = find_system(modelName, 'SearchDepth', 1, ...
            'FollowLinks', 'on', 'LookUnderMasks', 'all', 'BlockType', 'Outport');
        if ischar(outportPaths)
            outportPaths = {outportPaths};
        end

        % --- Engine 1: Headless Compilation Capture (Highly Accurate) ---
        hasCompileError = false;
        try
            % Headlessly update diagram to force Simulink to resolve inherited sample times
            set_param(modelName, 'SimulationCommand', 'update');
        catch compileErr
            errMessage = compileErr.message;
            if contains(errMessage, 'Invalid root Outport block connection') || ...
               contains(errMessage, 'constant sample time')
                
                hasCompileError = true;
                % Attempt to extract the Outport number from the error message
                portIdxStr = regexp(errMessage, 'Root Outport (\d+)', 'tokens', 'once');
                targetOutportPath = '';
                targetOutportName = 'Unknown';
                
                if ~isempty(portIdxStr)
                    portNum = portIdxStr{1};
                    matchedOutports = find_system(modelName, 'SearchDepth', 1, ...
                        'BlockType', 'Outport', 'Port', portNum);
                    if ~isempty(matchedOutports)
                        targetOutportPath = matchedOutports{1};
                        targetOutportName = get_param(targetOutportPath, 'Name');
                    end
                end
                
                if isempty(targetOutportPath) && ~isempty(outportPaths)
                    targetOutportPath = outportPaths{1};
                    targetOutportName = get_param(targetOutportPath, 'Name');
                end
                
                if ~isempty(targetOutportPath)
                    issues(end + 1) = struct( ... %#ok<AGROW>
                        'Category', 'SampleTime', ...
                        'Severity', 'error', ...
                        'Model', modelName, ...
                        'Port', targetOutportName, ...
                        'Description', sprintf(['Simulink compiler error: Root Outport "%s" ' ...
                            'is driven by a constant signal but lacks an explicit constant rate. ' ...
                            'Original diagnostic: %s'], targetOutportName, cleanHyperlinks(errMessage)), ...
                        'FixMethod', 'SetOutportConstant', ...
                        'FixData', struct( ...
                            'ModelName', modelName, ...
                            'OutportPath', targetOutportPath));
                end
            end
        end

        % --- Engine 2: Deep Recursive Static Signal Trace ---
        if ~hasCompileError
            for j = 1:numel(outportPaths)
                outportPath = outportPaths{j};
                outportName = get_param(outportPath, 'Name');
                try
                    outportST = strtrim(get_param(outportPath, 'SampleTime'));
                    if strcmpi(outportST, 'inf')
                        continue;
                    end

                    visited = {};
                    if traceSignalSourceIsConstant(modelName, outportPath, visited, 15)
                        issues(end + 1) = struct( ... %#ok<AGROW>
                            'Category', 'SampleTime', ...
                            'Severity', 'error', ...
                            'Model', modelName, ...
                            'Port', outportName, ...
                            'Description', sprintf(['Root Outport "%s" in model "%s" has ' ...
                                'SampleTime = "%s", but its signal trace is Constant. ' ...
                                'This triggers an "Invalid root Outport block connection" compile failure.'], ...
                                outportName, modelName, outportST), ...
                            'FixMethod', 'SetOutportConstant', ...
                            'FixData', struct( ...
                                'ModelName', modelName, ...
                                'OutportPath', outportPath));
                        break; % Avoid duplicate issues for the same target
                    end
                catch
                end
            end
        end

        if openedByUs
            close_system(modelName, 0);
        end
    catch modelErr
        if openedByUs
            try close_system(modelName, 0); catch, end
        end
        issues(end + 1) = struct( ... %#ok<AGROW>
            'Category', 'Info', 'Severity', 'warning', ...
            'Model', modelName, 'Port', '', ...
            'Description', sprintf('Could not analyze model "%s": %s', ...
                modelName, modelErr.message), ...
            'FixMethod', 'none', 'FixData', struct());
    end
end

progressFcn(1, 'Sample time check complete.');
end

function isConst = traceSignalSourceIsConstant(modelName, blockPath, visited, depthLeft)
isConst = false;
if depthLeft <= 0 || ismember(blockPath, visited), return; end
visited{end + 1} = blockPath;
try bType = get_param(blockPath, 'BlockType'); catch, return; end

if strcmp(bType, 'Constant') || strcmp(bType, 'Ground') || strcmp(bType, 'EnumeratedConstant')
    isConst = true; return;
end
try
    stVal = strtrim(get_param(blockPath, 'SampleTime'));
    if strcmpi(stVal, 'inf')
        isConst = true; return;
    elseif ~isempty(stVal) && ~strcmp(stVal, '-1') && ~strcmp(stVal, '[ -1, -1 ]')
        isConst = false; return;
    end
catch
end
if strcmp(bType, 'Inport') && strcmp(get_param(blockPath, 'Parent'), modelName)
    isConst = false; return;
end
if strcmp(bType, 'From')
    try
        tag = get_param(blockPath, 'GotoTag');
        gotoList = find_system(modelName, 'FollowLinks', 'on', 'LookUnderMasks', 'all', ...
            'BlockType', 'Goto', 'GotoTag', tag);
        if ~isempty(gotoList)
            isConst = traceSignalSourceIsConstant(modelName, gotoList{1}, visited, depthLeft - 1);
        end
    catch
    end
    return;
end
if strcmp(bType, 'Goto')
    pH = get_param(blockPath, 'PortHandles');
    if ~isempty(pH.Inport)
        line = get_param(pH.Inport(1), 'LineHandle');
        if line ~= -1
            srcPort = get_param(line, 'SrcPortHandle');
            if srcPort ~= -1
                isConst = traceSignalSourceIsConstant(modelName, get_param(srcPort, 'Parent'), visited, depthLeft - 1);
            end
        end
    end
    return;
end
if strcmp(bType, 'SubSystem')
    try
        subOutports = find_system(blockPath, 'SearchDepth', 1, 'BlockType', 'Outport');
        if ~isempty(subOutports)
            isConst = true;
            for s = 1:numel(subOutports)
                if ~traceSignalSourceIsConstant(modelName, subOutports{s}, visited, depthLeft - 1)
                    isConst = false; return;
                end
            end
        end
    catch
    end
    return;
end
try
    pH = get_param(blockPath, 'PortHandles');
    inports = pH.Inport;
    if isempty(inports), return; end
    isConst = true;
    for k = 1:numel(inports)
        line = get_param(inports(k), 'LineHandle');
        if line == -1, isConst = false; return; end
        srcPort = get_param(line, 'SrcPortHandle');
        if srcPort == -1, isConst = false; return; end
        if ~traceSignalSourceIsConstant(modelName, get_param(srcPort, 'Parent'), visited, depthLeft - 1)
            isConst = false; return;
        end
    end
catch
    isConst = false;
end
end

function text = cleanHyperlinks(text)
text = regexprep(text, '<a[^>]*>\s*([^<]*?)\s*</a>', '$1');
end

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