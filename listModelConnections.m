function [connections, stats] = listModelConnections(systemName)
%LISTMODELCONNECTIONS Model-to-Model signal connections in a block diagram.
%
%   [connections, stats] = listModelConnections(sys)
%
% Returns a struct array describing every signal connection between Model
% Reference blocks found anywhere in the diagram "sys" (the referenced
% models themselves are NOT searched). Both connection kinds are found:
%   - direct lines from a model output to a model input
%   - From/Goto links: a model output feeding a Goto block whose tag is
%     read by a From block that feeds a model input
%
% Only BACKWARD connections and SELF-LOOPS are returned.

sys = char(systemName);
if ~bdIsLoaded(sys)
    error('listModelConnections:ModelNotLoaded', ...
        'The model is not loaded: %s', sys);
end

stats = struct('BlocksScanned', 0, 'ModelBlocks', 0, ...
    'ConnectedOutputs', 0, 'Connections', 0, ...
    'FromGotoConnections', 0, 'AmbiguousTags', 0, ...
    'GotoBlocks', 0, 'FromBlocks', 0, 'UnitDelayBlocks', 0);

connections = struct( ...
    'System', {}, 'SrcBlock', {}, 'SrcBlockPath', {}, ...
    'SrcPortIndex', {}, 'SrcPortName', {}, ...
    'DstBlock', {}, 'DstBlockPath', {}, 'DstPortIndex', {}, 'DstPortName', {}, ...
    'Label', {}, 'Kind', {}, 'Tag', {}, ...
    'GotoBlockPath', {}, 'FromBlockPath', {}, 'AlreadyDelayed', {});

stage = 'starting';
try
    stage = 'scanning the diagram for blocks';
    allBlocks = find_system(sys, 'LookUnderMasks', 'on', 'Type', 'block');
    if isempty(allBlocks)
        return;
    end
    if ischar(allBlocks)
        allBlocks = {allBlocks};
    end
    stats.BlocksScanned = numel(allBlocks);

    stage = 'identifying model-reference blocks';
    modelBlocks = {};
    for blockIndex = 1:numel(allBlocks)
        blockPath = allBlocks{blockIndex};
        try
            if strcmp(get_param(blockPath, 'BlockType'), 'Model')
                modelBlocks{end + 1} = blockPath; %#ok<AGROW>
            else
                nameOfModel = get_param(blockPath, 'ModelName');
                if ischar(nameOfModel) && ~isempty(strtrim(nameOfModel))
                    modelBlocks{end + 1} = blockPath; %#ok<AGROW>
                end
            end
        catch
        end
    end
    stats.ModelBlocks = numel(modelBlocks);
    if isempty(modelBlocks)
        return;
    end
    modelBlocks = modelBlocks(:)';

    stage = 'collecting Goto, From and Unit Delay blocks';
    gotoPaths = {};
    gotoTags = {};
    gotoInportHandles = [];
    fromPaths = {};
    fromTags = {};
    fromOutportHandles = [];
    delayInportHandles = [];
    delayOutportHandles = [];
    for blockIndex = 1:numel(allBlocks)
        blockPath = allBlocks{blockIndex};
        try
            blockType = char(get_param(blockPath, 'BlockType'));
            if strcmp(blockType, 'Goto')
                gotoPaths{end + 1} = blockPath; %#ok<AGROW>
                gotoTags{end + 1} = strtrim(char(get_param(blockPath, 'GotoTag'))); %#ok<AGROW>
                gotoInportHandles(end + 1) = get_param(blockPath, 'PortHandles').Inport(1); %#ok<AGROW>
            elseif strcmp(blockType, 'From')
                fromPaths{end + 1} = blockPath; %#ok<AGROW>
                fromTags{end + 1} = strtrim(char(get_param(blockPath, 'GotoTag'))); %#ok<AGROW>
                fromOutportHandles(end + 1) = get_param(blockPath, 'PortHandles').Outport(1); %#ok<AGROW>
            elseif strcmp(blockType, 'UnitDelay')
                delayInportHandles(end + 1) = get_param(blockPath, 'PortHandles').Inport(1); %#ok<AGROW>
                delayOutportHandles(end + 1) = get_param(blockPath, 'PortHandles').Outport(1); %#ok<AGROW>
            end
        catch
        end
    end
    stats.GotoBlocks = numel(gotoPaths);
    stats.FromBlocks = numel(fromPaths);
    stats.UnitDelayBlocks = numel(delayInportHandles);

    stage = 'mapping model-reference input ports';
    modelInportHandles = [];
    modelInportOwner = zeros(1, 0);
    for modelIndex = 1:numel(modelBlocks)
        inportHandles = get_param(modelBlocks{modelIndex}, 'PortHandles').Inport;
        modelInportHandles = [modelInportHandles, inportHandles(:)']; %#ok<AGROW>
        modelInportOwner = [modelInportOwner, repmat(modelIndex, 1, numel(inportHandles))]; %#ok<AGROW>
    end

    pendingGotos = struct('SrcBlock', {}, 'SrcBlockPath', {}, ...
        'SrcPortIndex', {}, 'SrcPortName', {}, ...
        'GotoBlockPath', {}, 'Tag', {}, 'AlreadyDelayed', {});
    pendingFroms = struct('FromBlockPath', {}, 'Tag', {}, ...
        'DstBlock', {}, 'DstBlockPath', {}, ...
        'DstPortIndex', {}, 'DstPortName', {}, 'AlreadyDelayed', {});

    stage = 'tracing signal lines';
    for sourceIndex = 1:numel(modelBlocks)
        srcPath = modelBlocks{sourceIndex};
        srcName = char(get_param(srcPath, 'Name'));
        srcPorts = get_param(srcPath, 'PortHandles');

        for outputIndex = 1:numel(srcPorts.Outport)
            topLine = get_param(srcPorts.Outport(outputIndex), 'Line');
            if ~isnumeric(topLine) || isempty(topLine) || any(topLine(:) == -1)
                continue;
            end
            topLine = topLine(1);
            stats.ConnectedOutputs = stats.ConnectedOutputs + 1;

            lineHandles = topLine(:)';
            children = get_param(topLine, 'LineChildren');
            if isnumeric(children) && ~isempty(children) && ~any(children(:) == -1)
                lineHandles = [lineHandles, children(:)']; %#ok<AGROW>
            end

            for lineIndex = 1:numel(lineHandles)
                dstPortHandle = get_param(lineHandles(lineIndex), 'DstPortHandle');
                if ~isnumeric(dstPortHandle) || isempty(dstPortHandle) || any(dstPortHandle(:) == -1)
                    continue;
                end
                dstPortHandle = dstPortHandle(1);

                [finalPorts, sawDelay] = expandThroughDelays( ...
                    dstPortHandle, delayInportHandles, delayOutportHandles);
                if isempty(finalPorts)
                    continue;
                end

                for finalIndex = 1:numel(finalPorts)
                    finalPort = finalPorts(finalIndex);
                    destIndex = find(modelInportHandles == finalPort, 1);
                    if isempty(destIndex)
                        gotoIndex = find(gotoInportHandles == finalPort, 1);
                        if ~isempty(gotoIndex) && strcmp(fileparts(srcPath), fileparts(gotoPaths{gotoIndex}))
                            pendingGotos(end + 1) = struct( ...
                                'SrcBlock',       srcName, ...
                                'SrcBlockPath',   srcPath, ...
                                'SrcPortIndex',   outputIndex, ...
                                'SrcPortName',    resolvePortName(srcPath, outputIndex, 'out'), ...
                                'GotoBlockPath',  gotoPaths{gotoIndex}, ...
                                'Tag',            gotoTags{gotoIndex}, ...
                                'AlreadyDelayed', sawDelay); %#ok<AGROW>
                        end
                        continue;
                    end

                    destBlock = modelBlocks{modelInportOwner(destIndex)};
                    dstName = char(get_param(destBlock, 'Name'));
                    dstPorts = get_param(destBlock, 'PortHandles');
                    dstPortIndex = find(dstPorts.Inport(:) == finalPort, 1);
                    if isempty(dstPortIndex)
                        continue;
                    end

                    srcPortName = resolvePortName(srcPath, outputIndex, 'out');
                    dstPortName = resolvePortName(destBlock, dstPortIndex, 'in');

                    if isempty(srcPortName), srcPortLabel = num2str(outputIndex); else, srcPortLabel = srcPortName; end
                    if isempty(dstPortName), dstPortLabel = num2str(dstPortIndex); else, dstPortLabel = dstPortName; end
                    if sawDelay, delaySuffix = ' (has Unit Delay)'; else, delaySuffix = ''; end

                    if isBackwardConnection(srcPath, destBlock)
                        connections(end + 1) = struct( ...
                            'System',        fileparts(srcPath), ...
                            'SrcBlock',      srcName, ...
                            'SrcBlockPath',  srcPath, ...
                            'SrcPortIndex',  outputIndex, ...
                            'SrcPortName',   srcPortName, ...
                            'DstBlock',      dstName, ...
                            'DstBlockPath',  destBlock, ...
                            'DstPortIndex',  dstPortIndex, ...
                            'DstPortName',   dstPortName, ...
                            'Label',         sprintf('%s.%s -> %s.%s%s', ...
                                                     srcName, srcPortLabel, ...
                                                     dstName, dstPortLabel, delaySuffix), ...
                            'Kind',          'line', ...
                            'Tag',           '', ...
                            'GotoBlockPath', '', ...
                            'FromBlockPath', '', ...
                            'AlreadyDelayed', sawDelay); %#ok<AGROW>
                    end
                end
            end
        end
    end

    stage = 'tracing From blocks to model inputs';
    for fromIndex = 1:numel(fromPaths)
        fromLine = get_param(fromOutportHandles(fromIndex), 'Line');
        if ~isnumeric(fromLine) || isempty(fromLine) || any(fromLine(:) == -1)
            continue;
        end
        fromLine = fromLine(1);

        lineHandles = fromLine(:)';
        children = get_param(fromLine, 'LineChildren');
        if isnumeric(children) && ~isempty(children) && ~any(children(:) == -1)
            lineHandles = [lineHandles, children(:)']; %#ok<AGROW>
        end

        for lineIndex = 1:numel(lineHandles)
            dstPortHandle = get_param(lineHandles(lineIndex), 'DstPortHandle');
            if ~isnumeric(dstPortHandle) || isempty(dstPortHandle) || any(dstPortHandle(:) == -1)
                continue;
            end
            dstPortHandle = dstPortHandle(1);

            [finalPorts, sawDelay] = expandThroughDelays( ...
                dstPortHandle, delayInportHandles, delayOutportHandles);

            for finalIndex = 1:numel(finalPorts)
                destIndex = find(modelInportHandles == finalPorts(finalIndex), 1);
                if isempty(destIndex)
                    continue;
                end
                destBlock = modelBlocks{modelInportOwner(destIndex)};
                dstName = char(get_param(destBlock, 'Name'));
                dstPorts = get_param(destBlock, 'PortHandles');
                dstPortIndex = find(dstPorts.Inport(:) == finalPorts(finalIndex), 1);
                if isempty(dstPortIndex)
                    continue;
                end

                pendingFroms(end + 1) = struct( ...
                    'FromBlockPath', fromPaths{fromIndex}, ...
                    'Tag',           fromTags{fromIndex}, ...
                    'DstBlock',      dstName, ...
                    'DstBlockPath',  destBlock, ...
                    'DstPortIndex',  dstPortIndex, ...
                    'DstPortName',   resolvePortName(destBlock, dstPortIndex, 'in'), ...
                    'AlreadyDelayed', sawDelay); %#ok<AGROW>
            end
        end
    end

    stage = 'pairing From and Goto tags';
    for pendingIndex = 1:numel(pendingFroms)
        matchIndexes = [];
        for gotoEntryIndex = 1:numel(pendingGotos)
            if strcmp(pendingFroms(pendingIndex).Tag, pendingGotos(gotoEntryIndex).Tag)
                matchIndexes(end + 1) = gotoEntryIndex; %#ok<AGROW>
            end
        end
        if isempty(matchIndexes)
            continue;
        end
        if numel(matchIndexes) > 1
            stats.AmbiguousTags = stats.AmbiguousTags + 1;
            continue;
        end

        gotoEntry = pendingGotos(matchIndexes(1));
        fromEntry = pendingFroms(pendingIndex);
        pathIsDelayed = gotoEntry.AlreadyDelayed || fromEntry.AlreadyDelayed;

        if isempty(gotoEntry.SrcPortName), srcPortLabel = num2str(gotoEntry.SrcPortIndex); else, srcPortLabel = gotoEntry.SrcPortName; end
        if isempty(fromEntry.DstPortName), dstPortLabel = num2str(fromEntry.DstPortIndex); else, dstPortLabel = fromEntry.DstPortName; end
        if pathIsDelayed, delaySuffix = ' (has Unit Delay)'; else, delaySuffix = ''; end

        if isBackwardConnection(gotoEntry.SrcBlockPath, fromEntry.DstBlockPath)
            connections(end + 1) = struct( ...
                'System',        fileparts(fromEntry.FromBlockPath), ...
                'SrcBlock',      gotoEntry.SrcBlock, ...
                'SrcBlockPath',  fromEntry.FromBlockPath, ...
                'SrcPortIndex',  1, ...
                'SrcPortName',   gotoEntry.SrcPortName, ...
                'DstBlock',      fromEntry.DstBlock, ...
                'DstBlockPath',  fromEntry.DstBlockPath, ...
                'DstPortIndex',  fromEntry.DstPortIndex, ...
                'DstPortName',   fromEntry.DstPortName, ...
                'Label',         sprintf('%s.%s --[%s]--> %s.%s%s', ...
                                         gotoEntry.SrcBlock, srcPortLabel, ...
                                         gotoEntry.Tag, fromEntry.DstBlock, ...
                                         dstPortLabel, delaySuffix), ...
                'Kind',          'fromgoto', ...
                'Tag',           gotoEntry.Tag, ...
                'GotoBlockPath', gotoEntry.GotoBlockPath, ...
                'FromBlockPath', fromEntry.FromBlockPath, ...
                'AlreadyDelayed', pathIsDelayed); %#ok<AGROW>
            stats.FromGotoConnections = stats.FromGotoConnections + 1;
        end
    end

    stats.Connections = numel(connections);
catch scanError
    error('listModelConnections:ScanFailed', ...
        ['Could not list the connections of "%s" (stage: %s).\n', ...
         'Original error: %s'], ...
        sys, stage, errorText(scanError));
end
end

function tf = isBackwardConnection(srcModelPath, dstModelPath)
%ISBACKWARDCONNECTION True when dominant direction is backward or a self-loop.

% CRITICAL FIX: Explicitly treat self-loops as backward connections needing delay
if strcmp(srcModelPath, dstModelPath)
    tf = true;
    return;
end

try
    srcPos = get_param(srcModelPath, 'Position');
    dstPos = get_param(dstModelPath, 'Position');
catch
    tf = true;
    return;
end

srcCx = (srcPos(1) + srcPos(3)) / 2;
srcCy = (srcPos(2) + srcPos(4)) / 2;
dstCx = (dstPos(1) + dstPos(3)) / 2;
dstCy = (dstPos(2) + dstPos(4)) / 2;
dx = srcCx - dstCx;   % > 0: source RIGHT of destination
dy = srcCy - dstCy;   % > 0: source BELOW destination
tol = 5;
if abs(dy) >= abs(dx)
    tf = dy > tol;    % vertical-dominant: bottom->top
else
    tf = dx > tol;    % horizontal-dominant: right->left
end
end

function [finalPorts, sawDelay] = expandThroughDelays(portHandle, delayInportHandles, delayOutportHandles, depth)
if nargin < 4, depth = 0; end
if depth > 8
    finalPorts = [];
    sawDelay = true;
    return;
end

finalPorts = portHandle;
sawDelay = false;
delayIndex = find(delayInportHandles == portHandle, 1);
if isempty(delayIndex), return; end
sawDelay = true;

outLine = get_param(delayOutportHandles(delayIndex), 'Line');
if ~isnumeric(outLine) || isempty(outLine) || any(outLine(:) == -1)
    finalPorts = [];
    return;
end
outLine = outLine(1);

lineHandles = outLine(:)';
children = get_param(outLine, 'LineChildren');
if isnumeric(children) && ~isempty(children) && ~any(children(:) == -1)
    lineHandles = [lineHandles, children(:)']; %#ok<AGROW>
end

finalPorts = [];
for lineIndex = 1:numel(lineHandles)
    dstPortHandle = get_param(lineHandles(lineIndex), 'DstPortHandle');
    if ~isnumeric(dstPortHandle) || isempty(dstPortHandle) || any(dstPortHandle(:) == -1)
        continue;
    end
    for portIndex = 1:numel(dstPortHandle)
        [subPorts, subDelay] = expandThroughDelays( ...
            dstPortHandle(portIndex), delayInportHandles, delayOutportHandles, depth + 1);
        finalPorts = [finalPorts, subPorts(:)']; %#ok<AGROW>
        sawDelay = sawDelay || subDelay;
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
        if ~isempty(causeText)
            text = [text newline '   ' causeText]; %#ok<AGROW>
        end
    end
end
text = regexprep(text, '<a[^>]*>\s*([^<]*?)\s*</a>', '$1');
end

function portName = resolvePortName(blockPath, portIndex, kind)
portName = '';
try
    referencedModel = get_param(blockPath, 'ModelName');
    if isempty(referencedModel) || ~bdIsLoaded(referencedModel), return; end

    inBlocks = find_system(referencedModel, 'SearchDepth', 1, ...
        'FollowLinks', 'on', 'LookUnderMasks', 'all', 'BlockType', 'Inport');
    outBlocks = find_system(referencedModel, 'SearchDepth', 1, ...
        'FollowLinks', 'on', 'LookUnderMasks', 'all', 'BlockType', 'Outport');

    if strcmp(kind, 'out'), blocks = outBlocks; else, blocks = inBlocks; end
    if isempty(blocks), return; end

    portNumbers = zeros(numel(blocks), 1);
    for blockIndex = 1:numel(blocks)
        portNumbers(blockIndex) = str2double(char(get_param(blocks(blockIndex), 'Port')));
    end
    [~, order] = sort(portNumbers);
    orderedBlocks = blocks(order);

    if portIndex >= 1 && portIndex <= numel(orderedBlocks)
        name = char(get_param(orderedBlocks(portIndex), 'Name'));
        portName = strtrim(name);
    end
catch
    portName = '';
end
end