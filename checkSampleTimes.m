function issues = checkSampleTimes(modelsFolder, selectedModels, progressFcn)
%CHECKSAMPLETIMES Deep-scans root Outports across all referenced models to
% detect signals driven by constant sources (Constant blocks, Ground,
% parameters, Goto/From tags, or internal Subsystems) where the Outport
% is not explicitly declared as SampleTime = 'Inf'.
%
% This prevents Simulink's fatal "Invalid root Outport block connection"
% error during parent model generation.

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

        % Check model-level diagnostic setting
        diagSetting = 'error';
        try
            diagSetting = get_param(modelName, 'InvalidRootInportOutportConnection');
        catch
        end

        outportPaths = find_system(modelName, 'SearchDepth', 1, ...
            'FollowLinks', 'on', 'LookUnderMasks', 'all', 'BlockType', 'Outport');
        if ischar(outportPaths)
            outportPaths = {outportPaths};
        end

        for j = 1:numel(outportPaths)
            outportPath = outportPaths{j};
            outportName = get_param(outportPath, 'Name');

            try
                outportST = strtrim(get_param(outportPath, 'SampleTime'));
                
                % If already explicitly set to Inf/inf, it is valid
                if strcmpi(outportST, 'inf')
                    continue;
                end

                % Deep-trace backward through Goto/From, Subsystems, and blocks
                visitedBlocks = {};
                isConst = traceSignalSourceIsConstant(modelName, outportPath, visitedBlocks, 15);

                if isConst
                    issues(end + 1) = struct( ... %#ok<AGROW>
                        'Category', 'SampleTime', ...
                        'Severity', 'error', ...
                        'Model', modelName, ...
                        'Port', outportName, ...
                        'Description', sprintf(['Root Outport "%s" in model "%s" has ' ...
                            'SampleTime = "%s", but is driven by a Constant source. ' ...
                            'Simulink will abort diagram build with "Invalid root ' ...
                            'Outport block connection".'], ...
                            outportName, modelName, outportST), ...
                        'FixMethod', 'SetOutportConstant', ...
                        'FixData', struct( ...
                            'ModelName', modelName, ...
                            'OutportPath', outportPath));
                end
            catch
                % Skip individual untraceable port
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

% =========================================================================
%  DEEP RECURSIVE SIGNAL TRACER (Goto/From, Subsystems, Math & Routing)
% =========================================================================
function isConst = traceSignalSourceIsConstant(modelName, blockPath, visited, depthLeft)
isConst = false;
if depthLeft <= 0 || ismember(blockPath, visited)
    return;
end
visited{end + 1} = blockPath;

try
    bType = get_param(blockPath, 'BlockType');
catch
    return;
end

% 1. Inherently Constant Sources
if strcmp(bType, 'Constant') || strcmp(bType, 'Ground') || strcmp(bType, 'EnumeratedConstant')
    isConst = true;
    return;
end

% 2. Explicit Constant Sample Time on the block itself
try
    stVal = strtrim(get_param(blockPath, 'SampleTime'));
    if strcmpi(stVal, 'inf')
        isConst = true;
        return;
    elseif ~isempty(stVal) && ~strcmp(stVal, '-1') && ~strcmp(stVal, '[ -1, -1 ]')
        % Explicit discrete or continuous rate (not constant)
        isConst = false;
        return;
    end
catch
end

% 3. Inport at root level inherits from outside (not locally constant)
if strcmp(bType, 'Inport') && strcmp(get_param(blockPath, 'Parent'), modelName)
    isConst = false;
    return;
end

% 4. Handle "From" Block (Cross-reference Goto tag)
if strcmp(bType, 'From')
    try
        tag = get_param(blockPath, 'GotoTag');
        gotoList = find_system(modelName, 'FollowLinks', 'on', 'LookUnderMasks', 'all', ...
            'BlockType', 'Goto', 'GotoTag', tag);
        if ~isempty(gotoList)
            gotoBlock = gotoList{1};
            isConst = traceSignalSourceIsConstant(modelName, gotoBlock, visited, depthLeft - 1);
        end
    catch
    end
    return;
end

% 5. Handle "Goto" Block
if strcmp(bType, 'Goto')
    portHandles = get_param(blockPath, 'PortHandles');
    if ~isempty(portHandles.Inport)
        line = get_param(portHandles.Inport(1), 'LineHandle');
        if line ~= -1
            srcPort = get_param(line, 'SrcPortHandle');
            if srcPort ~= -1
                srcBlock = get_param(srcPort, 'Parent');
                isConst = traceSignalSourceIsConstant(modelName, srcBlock, visited, depthLeft - 1);
            end
        end
    end
    return;
end

% 6. Handle "SubSystem" Block (Trace internal Outport driving this output)
if strcmp(bType, 'SubSystem')
    % When tracing a Subsystem output, find which Inport block of the Outport was connected
    % Default to inspecting Outport blocks inside the subsystem
    try
        subOutports = find_system(blockPath, 'SearchDepth', 1, 'BlockType', 'Outport');
        if ~isempty(subOutports)
            isConst = true;
            for s = 1:numel(subOutports)
                if ~traceSignalSourceIsConstant(modelName, subOutports{s}, visited, depthLeft - 1)
                    isConst = false;
                    return;
                end
            end
        end
    catch
    end
    return;
end

% 7. General Block / Outport: Trace all driving input lines
try
    portHandles = get_param(blockPath, 'PortHandles');
    inports = portHandles.Inport;
    if isempty(inports)
        return;
    end

    isConst = true;
    for k = 1:numel(inports)
        line = get_param(inports(k), 'LineHandle');
        if line == -1
            isConst = false;
            return;
        end
        srcPort = get_param(line, 'SrcPortHandle');
        if srcPort == -1
            isConst = false;
            return;
        end
        srcBlock = get_param(srcPort, 'Parent');
        if ~traceSignalSourceIsConstant(modelName, srcBlock, visited, depthLeft - 1)
            isConst = false;
            return;
        end
    end
catch
    isConst = false;
end
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