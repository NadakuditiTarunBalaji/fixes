function issues = checkSampleTimes(modelsFolder, selectedModels, progressFcn)
%CHECKSAMPLETIMES Detect root Outports whose driving signal has a constant
% (inf) sample time while the Outport itself declares a non-constant sample
% time.  This is the exact condition that triggers Simulink's built-in
% "Invalid root Outport block connection" diagnostic during model update.
%
%   issues = checkSampleTimes(modelsFolder, selectedModels)
%   issues = checkSampleTimes(modelsFolder, selectedModels, progressFcn)
%
% ROOT CAUSE FIX (vs. the original version):
%   1. The driver check now walks the ENTIRE signal chain backward through
%      intermediate blocks (Gain, Data Type Conversion, Sum, etc.) instead
%      of only looking at the immediately connected block type.  This
%      catches "Constant -> Gain -> Outport" and similar chains.
%   2. The Outport condition now flags ANY non-constant sample time (not
%      just empty / -1), matching what Simulink's own diagnostic checks.
%   3. The FixMethod is 'SetOutportConstant' (set the Outport to Inf)
%      instead of 'InsertUnitDelay', which is the correct fix for a sample
%      time mismatch between a constant driver and a non-constant Outport.

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
                    'Description', sprintf( ...
                        'Model file not found for "%s" - sample time check skipped.', ...
                        modelName), ...
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

        for j = 1:numel(outportPaths)
            outportPath = outportPaths{j};
            outportName = get_param(outportPath, 'Name');

            try
                % --- FIX #2: check if the Outport declares a non-constant
                %     sample time (ANY value that is not 'inf') ---
                outportST = strtrim(get_param(outportPath, 'SampleTime'));
                isOutportNonConstant = isempty(outportST) || ...
                    ~strcmpi(outportST, 'inf');

                if ~isOutportNonConstant
                    continue;   % Outport is explicitly constant — no mismatch
                end

                % --- FIX #1: trace the FULL signal chain backward to
                %     determine whether the driving signal is constant ---
                if ~isDrivenByConstantSignal(outportPath, 8)
                    continue;   % Driver is not constant — no mismatch
                end

                % Both conditions met: non-constant Outport + constant driver
                % This is the exact condition Simulink flags as
                % "Invalid root Outport block connection".
                issues(end + 1) = struct( ... %#ok<AGROW>
                    'Category', 'SampleTime', ...
                    'Severity', 'error', ...
                    'Model', modelName, ...
                    'Port', outportName, ...
                    'Description', sprintf(['Root Outport "%s" in model ' ...
                        '"%s" does not have a constant sample time ' ...
                        '(SampleTime = "%s") but is driven by a signal ' ...
                        'with a constant (inf) sample time. This will ' ...
                        'cause an "Invalid root Outport block connection" ' ...
                        'error when the model is referenced from a parent.'], ...
                        outportName, modelName, outportST), ...
                    'FixMethod', 'SetOutportConstant', ...
                    'FixData', struct( ...
                        'ModelName', modelName, ...
                        'OutportPath', outportPath));
            catch
                % A single port that cannot be traced should not abort
                % the whole scan - skip it and move on.
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
            'Description', sprintf('Could not fully analyze model "%s": %s', ...
                modelName, modelErr.message), ...
            'FixMethod', 'none', 'FixData', struct());
    end
end

progressFcn(1, 'Sample time check complete.');
end

% =========================================================================
%  SIGNAL-CHAIN TRACE HELPERS  (new — these are the root-cause fix)
% =========================================================================

function isConst = isDrivenByConstantSignal(outportPath, maxDepth)
%ISDRIVENBYCONSTANTSIGNAL Trace backward from a root Outport through the
% signal chain to determine whether the driving signal has a constant (inf)
% sample time.  Walks through intermediate blocks (Gain, Data Type
% Conversion, Sum, Bus Creator, etc.) up to maxDepth levels.
%
% Returns true only when the ultimate source of the signal is a block with
% a constant sample time (Constant, Ground, or any block whose SampleTime
% parameter is explicitly 'inf').

if nargin < 2, maxDepth = 8; end
isConst = false;

try
    portHandles = get_param(outportPath, 'PortHandles');
    inportHandle = portHandles.Inport;
    if isempty(inportHandle), return; end

    lineHandle = get_param(inportHandle, 'LineHandle');
    if isempty(lineHandle) || lineHandle == -1, return; end

    srcPortHandle = get_param(lineHandle, 'SrcPortHandle');
    if isempty(srcPortHandle) || srcPortHandle == -1, return; end

    isConst = traceConstantSampleTime(srcPortHandle, maxDepth);
catch
    isConst = false;
end
end

function isConst = traceConstantSampleTime(srcPortHandle, maxDepth)
%TRACECONSTANTSAMPLETIME Recursively walk backward through the signal
% chain starting at srcPortHandle.  Returns true when the signal at this
% point has a constant (inf) sample time.
%
% Decision logic at each block:
%   1. Inherently constant block types (Constant, Ground) → true
%   2. Explicit SampleTime parameter = 'inf'              → true
%   3. Explicit SampleTime parameter = other value         → false
%   4. Inport (inherits from parent, unknown statically)   → false
%   5. Otherwise: recurse into ALL input ports; the output
%      is constant only when every input is constant.

if maxDepth <= 0 || isempty(srcPortHandle) || srcPortHandle == -1
    isConst = false;
    return;
end

srcBlockPath = get_param(srcPortHandle, 'Parent');
srcBlockType = get_param(srcBlockPath, 'BlockType');

% --- Rule 1: inherently constant block types ---
if strcmp(srcBlockType, 'Constant') || strcmp(srcBlockType, 'Ground')
    isConst = true;
    return;
end

% --- Rule 2 & 3: explicit SampleTime parameter ---
try
    blockST = strtrim(get_param(srcBlockPath, 'SampleTime'));
    if strcmpi(blockST, 'inf')
        isConst = true;       % Rule 2
        return;
    elseif ~isempty(blockST) && ~strcmp(blockST, '-1')
        isConst = false;      % Rule 3: explicit non-constant rate
        return;
    end
    % '-1' or empty → inherited, keep tracing
catch
    % Block has no SampleTime parameter → inherited, keep tracing
end

% --- Rule 4: Inport inherits from the parent model ---
if strcmp(srcBlockType, 'Inport')
    isConst = false;
    return;
end

% --- Rule 5: recurse into all input ports ---
try
    portHandles = get_param(srcBlockPath, 'PortHandles');
    inports = portHandles.Inport;
    if isempty(inports)
        isConst = false;
        return;
    end

    % Normalize to a row vector (scalar handle vs. array)
    if isnumeric(inports) && isscalar(inports)
        inports = [inports];
    end

    % The output is constant only when EVERY input is constant.
    % (e.g. Sum with one constant and one discrete input → discrete output)
    isConst = true;
    for ip = 1:numel(inports)
        inLineHandle = get_param(inports(ip), 'LineHandle');
        if isempty(inLineHandle) || inLineHandle == -1
            isConst = false;   % Unconnected input → unknown
            return;
        end
        prevSrcPort = get_param(inLineHandle, 'SrcPortHandle');
        if ~traceConstantSampleTime(prevSrcPort, maxDepth - 1)
            isConst = false;
            return;
        end
    end
catch
    isConst = false;
end
end

% =========================================================================
%  FILE-FINDER HELPER  (unchanged)
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