function result = insertUnitDelayOnBranch(systemName, sourceBlockPath, outputPortIndex, destBlockPath, inputPortIndex, options)
%INSERTUNITDELAYONBRANCH Insert a Unit Delay on one connection branch.

if nargin < 6 || isempty(options)
    options = struct();
end
options = fillDefaults(options, struct('BlockName', '', 'SampleTime', '-1', 'BlockSpacing', 100));

sys = char(systemName);
srcPath = char(sourceBlockPath);
dstPath = char(destBlockPath);
outIdx = double(outputPortIndex);
inIdx = double(inputPortIndex);

topModel = strtok(sys, '/');
if ~bdIsLoaded(topModel)
    error('insertUnitDelayOnBranch:ModelNotLoaded', ...
        'The model is not loaded: %s', topModel);
end

try get_param(srcPath, 'Handle'); catch
    error('insertUnitDelayOnBranch:BlockNotFound', 'Source block not found: %s', srcPath);
end
try get_param(dstPath, 'Handle'); catch
    error('insertUnitDelayOnBranch:BlockNotFound', 'Destination block not found: %s', dstPath);
end

srcPorts = get_param(srcPath, 'PortHandles');
dstPorts = get_param(dstPath, 'PortHandles');

if outIdx < 1 || outIdx > numel(srcPorts.Outport)
    error('insertUnitDelayOnBranch:BadPort', 'Source block has no output port %d', outIdx);
end
if inIdx < 1 || inIdx > numel(dstPorts.Inport)
    error('insertUnitDelayOnBranch:BadPort', 'Destination block has no input port %d', inIdx);
end

srcPortHandle = srcPorts.Outport(outIdx);
dstPortHandle = dstPorts.Inport(inIdx);

stage = 'finding the signal line';
try
    topLine = get_param(srcPortHandle, 'Line');
    if ~isnumeric(topLine) || isempty(topLine) || any(topLine(:) == -1)
        error('insertUnitDelayOnBranch:NotConnected', 'Output port %d of "%s" is not connected.', outIdx, srcPath);
    end
    topLine = topLine(1);

    stage = 'collecting the signal destinations';
    lineHandles = collectAllLines(topLine);

    allDestinations = [];
    for lineIndex = 1:numel(lineHandles)
        d = get_param(lineHandles(lineIndex), 'DstPortHandle');
        if isnumeric(d) && ~isempty(d) && ~any(d(:) == -1)
            allDestinations = [allDestinations, d(:)']; %#ok<AGROW>
        end
    end

    if isempty(allDestinations) || ~any(allDestinations(:) == dstPortHandle)
        error('insertUnitDelayOnBranch:NotConnected', '"%s" is not connected to "%s".', srcPath, dstPath);
    end

    % HIGH-SEVERITY FIX: Collision-safe placement
    stage = 'calculating collision-safe position';
    spacing = max(55, round(double(options.BlockSpacing)));
    srcBlockPos = get_param(srcPath, 'Position');
    dstPortPos = get_param(dstPortHandle, 'Position');
    delayLeft = round(dstPortPos(1)) - 40 - spacing;
    if delayLeft < srcBlockPos(3) + spacing
        delayLeft = round((srcBlockPos(3) + dstPortPos(1)) / 2) - 20;
    end
    delayY = round(dstPortPos(2));
    delayPosition = [delayLeft, delayY - 10, delayLeft + 40, delayY + 10];

    % Collect existing block bounding boxes in sys to prevent overlaps
    existingBlocks = find_system(sys, 'SearchDepth', 1, 'Type', 'block');
    existingBlocks = existingBlocks(~strcmp(existingBlocks, sys));
    allRects = zeros(numel(existingBlocks), 4);
    for bIdx = 1:numel(existingBlocks)
        allRects(bIdx, :) = get_param(existingBlocks{bIdx}, 'Position');
    end

    % If occupied, bump slightly until clear
    shiftAttempts = 0;
    while isCollision(delayPosition, allRects) && shiftAttempts < 10
        delayPosition = delayPosition + [0, 25, 0, 25];
        shiftAttempts = shiftAttempts + 1;
    end

    [~, srcLeaf] = fileparts(srcPath);
    [~, dstLeaf] = fileparts(dstPath);
    baseName = char(options.BlockName);
    if isempty(baseName)
        counter = 1;
        blockName = sprintf('UnitDelay_%d', counter);
        while blockExists([sys '/' blockName])
            counter = counter + 1;
            blockName = sprintf('UnitDelay_%d', counter);
        end
    else
        blockName = baseName;
        suffix = 2;
        while blockExists([sys '/' blockName])
            blockName = sprintf('%s_%d', baseName, suffix);
            suffix = suffix + 1;
        end
    end

    stage = 'rewiring connections';
    for deleteIndex = 1:numel(lineHandles)
        try delete_line(lineHandles(deleteIndex)); catch; end
    end
    clearPortLine(srcPortHandle);
    clearPortLine(dstPortHandle);

    add_block('built-in/UnitDelay', [sys '/' blockName], 'Position', delayPosition);
    if ~strcmp(char(options.SampleTime), '-1')
        set_param([sys '/' blockName], 'SampleTime', char(options.SampleTime));
    end

    delayPorts = get_param([sys '/' blockName], 'PortHandles');
    tryConnect(sys, srcPortHandle, delayPorts.Inport(1));
    tryConnect(sys, delayPorts.Outport(1), dstPortHandle);

    reconnectFailed = 0;
    for destinationIndex = 1:numel(allDestinations)
        if allDestinations(destinationIndex) ~= dstPortHandle
            try
                clearPortLine(allDestinations(destinationIndex));
                tryConnect(sys, srcPortHandle, allDestinations(destinationIndex));
            catch
                reconnectFailed = reconnectFailed + 1;
            end
        end
    end
catch insertError
    error('insertUnitDelayOnBranch:Failed', ...
        ['Could not insert Unit Delay (stage: %s).\nOriginal error: %s'], ...
        stage, errorText(insertError));
end

result = struct( ...
    'NewBlockPath', [sys '/' blockName], ...
    'System',       sys, ...
    'Message',      sprintf('Unit Delay "%s" inserted: %s -> %s.', blockName, srcLeaf, dstLeaf));
end

function tf = isCollision(rect, allRects)
tf = false;
margin = 2;
lo = [rect(1) - margin, rect(2) - margin];
hi = [rect(3) + margin, rect(4) + margin];
for r = 1:size(allRects, 1)
    o = allRects(r, :);
    if lo(1) < o(3) && o(1) < hi(1) && lo(2) < o(4) && o(2) < hi(2)
        tf = true;
        return;
    end
end
end

function text = errorText(err)
text = strtrim(char(err.message));
if isempty(text), text = '(no message)'; end
for groupIndex = 1:numel(err.cause)
    causeGroup = err.cause{groupIndex};
    for causeIndex = 1:numel(causeGroup)
        causeText = strtrim(char(causeGroup(causeIndex).message));
        if ~isempty(causeText), text = [text newline '   ' causeText]; end
    end
end
text = regexprep(text, '<a[^>]*>\s*([^<]*?)\s*</a>', '$1');
end

function handles = collectAllLines(topLine)
handles = topLine(:)';
try
    children = get_param(topLine(1), 'LineChildren');
    if isnumeric(children) && ~isempty(children) && ~any(children(:) == -1)
        for childIndex = 1:numel(children)
            handles = [handles, collectAllLines(children(childIndex))]; %#ok<AGROW>
        end
    end
catch
end
end

function clearPortLine(portHandle)
for attempt = 1:3
    try lineHandle = get_param(portHandle, 'Line'); catch, return; end
    if ~isnumeric(lineHandle) || isempty(lineHandle) || any(lineHandle(:) == -1), return; end
    try delete_line(lineHandle(1)); catch; end
end
end

function tryConnect(systemName, srcPortHandle, dstPortHandle)
try
    add_line(systemName, srcPortHandle, dstPortHandle, 'autorouting', 'smart');
    return;
catch
end
try
    clearPortLine(dstPortHandle);
    add_line(systemName, srcPortHandle, dstPortHandle, 'autorouting', 'on');
catch connectError
    error('insertUnitDelayOnBranch:ConnectFailed', ...
        'Could not draw line. Error: %s', errorText(connectError));
end
end

function exists = blockExists(blockPath)
try get_param(blockPath, 'Handle'); exists = true; catch, exists = false; end
end

function options = fillDefaults(options, defaults)
if isempty(options), options = struct(); end
fields = fieldnames(defaults);
for index = 1:numel(fields)
    if ~isfield(options, fields{index})
        options.(fields{index}) = defaults.(fields{index});
    end
end
end