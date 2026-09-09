function result = arrangeModelLayout(systemName, options)
%ARRANGEMODELLAYOUT Engine for 100% orthogonal (horizontal & vertical only)
% block diagram arrangement with zero diagonals and zero overlaps.

if nargin < 2 || isempty(options), options = struct(); end

if ~isfield(options, 'FullRelayout'), options.FullRelayout = true; end
if ~isfield(options, 'Layout'), options.Layout = 'horizontal'; end
if ~isfield(options, 'SameSize'), options.SameSize = true; end
if ~isfield(options, 'AlignPortColumns'), options.AlignPortColumns = true; end
if ~isfield(options, 'TidyLines'), options.TidyLines = true; end

sys = char(systemName);
topModel = strtok(sys, '/');

if ~bdIsLoaded(topModel)
    error('arrangeModelLayout:ModelNotLoaded', 'Model not loaded: %s', topModel);
end
try
    get_param(sys, 'Handle');
catch
    error('arrangeModelLayout:SystemNotFound', 'System not found: %s', sys);
end

counts = struct( ...
    'ModelsResized', 0, 'FromGotoResized', 0, ...
    'InportsAligned', 0, 'OutportsAligned', 0, ...
    'TagBlocksAligned', 0, 'TagBlocksRespaced', 0, ...
    'LinesStraightened', 0, 'LinesLeftAuto', 0);
warningsList = {};
backupFile = '';

stage = 'reading diagram';
try
    blocks = find_system(sys, 'SearchDepth', 1, 'LookUnderMasks', 'on', 'Type', 'block');
    if ischar(blocks), blocks = {blocks}; end
    blocks = blocks(~strcmp(blocks, sys));
    nBlocks = numel(blocks);

    if nBlocks == 0
        result = struct('System', sys, 'Counts', counts, ...
            'Warnings', {{'No blocks to arrange.'}}, 'BackupFile', '');
        return;
    end

    blockType = cell(1, nBlocks);
    for b = 1:nBlocks
        blockType{b} = char(get_param(blocks{b}, 'BlockType'));
    end

    origConns = snapshotConns(blocks);

    if options.FullRelayout
        stage = 'orthogonal grid re-layout';
        counts = doOrthogonalPipelineRelayout(sys, blocks, blockType, options, counts);
    else
        stage = 'conservative layout';
        counts = doConservativeLayout(sys, blocks, blockType, options, counts);
    end

    % Verify connectivity unchanged
    newConns = snapshotConns(blocks);
    if ~isequal(sort(origConns), sort(newConns))
        error('arrangeModelLayout:VerifyFailed', 'Connections changed during arrange.');
    end

    % Backup and save
    stage = 'saving';
    try
        modelFile = get_param(topModel, 'FileName');
        if ~isempty(modelFile) && isfile(modelFile)
            backupFile = [modelFile '.bak'];
            copyfile(modelFile, backupFile);
        end
    catch
    end
    set_param(topModel, 'SimulationCommand', 'update');
    save_system(topModel);

    result = struct('System', sys, 'Counts', counts, ...
        'Warnings', {warningsList}, 'BackupFile', backupFile);

catch arrangeError
    error('arrangeModelLayout:ArrangeFailed', ...
        'Arrange failed at stage "%s": %s', stage, arrangeError.message);
end
end

% =========================================================================
%  100% ORTHOGONAL PIPELINE RELAYOUT ENGINE
% =========================================================================
function counts = doOrthogonalPipelineRelayout(sys, blocks, blockType, options, counts)

modelIdx  = find(strcmp(blockType, 'Model') | strcmp(blockType, 'SubSystem'));
inportIdx = find(strcmp(blockType, 'Inport'));
outportIdx= find(strcmp(blockType, 'Outport'));
fromIdx   = find(strcmp(blockType, 'From'));
gotoIdx   = find(strcmp(blockType, 'Goto'));
delayIdx  = find(strcmp(blockType, 'UnitDelay'));

nModels = numel(modelIdx);
if nModels == 0, return; end

% 1. Auto-size From/Goto blocks based on tag text length (No text truncation)
for f = [fromIdx, gotoIdx]
    try
        tag = char(get_param(blocks{f}, 'GotoTag'));
        reqW = max(100, ceil(numel(tag) * 8.5) + 30);
        r = get_param(blocks{f}, 'Position');
        if strcmp(get_param(blocks{f}, 'BlockType'), 'From')
            set_param(blocks{f}, 'Position', [r(3) - reqW, r(2), r(3), r(4)]);
        else
            set_param(blocks{f}, 'Position', [r(1), r(2), r(1) + reqW, r(4)]);
        end
        counts.FromGotoResized = counts.FromGotoResized + 1;
    catch
    end
end

% 2. Calculate Model Reference Heights (Dynamic per port count, strict 36px pitch)
modelWidths = zeros(nModels, 1);
modelHeights = zeros(nModels, 1);
for k = 1:nModels
    m = modelIdx(k);
    r = get_param(blocks{m}, 'Position');
    p = get_param(blocks{m}, 'PortHandles');
    nP = max([numel(p.Inport), numel(p.Outport), 1]);
    modelWidths(k) = max(260, r(3) - r(1));
    modelHeights(k) = max(140, (nP + 1) * 36);
end

if options.SameSize
    uniformH = max(modelHeights);
    modelHeights(:) = uniformH;
end

% 3. Far-Left Root Inports & Root Goto Clearance
inportX = 50;
inportW = 35;
rootGotoX = inportX + inportW + 40;

maxRootGotoW = 100;
for i = 1:numel(inportIdx)
    p = get_param(blocks{inportIdx(i)}, 'PortHandles');
    l = get_param(p.Outport(1), 'Line');
    if l ~= -1
        dsts = get_param(l, 'DstPortHandle');
        for d = 1:numel(dsts)
            if dsts(d) ~= -1 && strcmp(get_param(get_param(dsts(d), 'Parent'), 'BlockType'), 'Goto')
                gBlock = get_param(dsts(d), 'Parent');
                r = get_param(gBlock, 'Position');
                maxRootGotoW = max(maxRootGotoW, r(3) - r(1));
            end
        end
    end
end
rootGotoRight = rootGotoX + maxRootGotoW;

% 4. Dynamic Horizontal X-Coordinate Placement for Models
modelPositions = zeros(nModels, 4);
fromModelGap = 60;
gotoModelGap = 60;
delayWidth   = 40;
delayGap     = 30;
modelBaseY   = 200;

currentX = rootGotoRight + 80;

for k = 1:nModels
    m = modelIdx(k);
    p = get_param(blocks{m}, 'PortHandles');

    maxFromW = 100;
    hasDelay = false;
    for inP = 1:numel(p.Inport)
        l = get_param(p.Inport(inP), 'Line');
        if l == -1, continue; end
        srcP = get_param(l, 'SrcPortHandle');
        if srcP == -1, continue; end
        srcB = get_param(srcP, 'Parent');
        bType = get_param(srcB, 'BlockType');
        
        if strcmp(bType, 'UnitDelay')
            hasDelay = true;
            dL = get_param(get_param(srcB, 'PortHandles').Inport(1), 'Line');
            if dL ~= -1
                dLsrc = get_param(dL, 'SrcPortHandle');
                if dLsrc ~= -1
                    fB = get_param(dLsrc, 'Parent');
                    if strcmp(get_param(fB, 'BlockType'), 'From')
                        r = get_param(fB, 'Position');
                        maxFromW = max(maxFromW, r(3) - r(1));
                    end
                end
            end
        elseif strcmp(bType, 'From')
            r = get_param(srcB, 'Position');
            maxFromW = max(maxFromW, r(3) - r(1));
        end
    end

    leftSpace = fromModelGap + maxFromW + (hasDelay * (delayWidth + delayGap));
    mX = currentX + leftSpace;
    mY = modelBaseY;
    mW = modelWidths(k);
    mH = modelHeights(k);

    newPos = [mX, mY, mX + mW, mY + mH];
    set_param(blocks{m}, 'Position', newPos);
    modelPositions(k, :) = newPos;
    counts.ModelsResized = counts.ModelsResized + 1;

    maxGotoW = 100;
    for outP = 1:numel(p.Outport)
        l = get_param(p.Outport(outP), 'Line');
        if l == -1, continue; end
        dsts = get_param(l, 'DstPortHandle');
        for d = 1:numel(dsts)
            if dsts(d) ~= -1
                dstB = get_param(dsts(d), 'Parent');
                if strcmp(get_param(dstB, 'BlockType'), 'Goto')
                    r = get_param(dstB, 'Position');
                    maxGotoW = max(maxGotoW, r(3) - r(1));
                end
            end
        end
    end

    currentX = mX + mW + gotoModelGap + maxGotoW + 60;
end

topModel = strtok(sys, '/');
set_param(topModel, 'SimulationCommand', 'update');

% 5. Align Blocks to Exact Port Y (Guarantees 100% Flat Horizontal Lines)
for k = 1:nModels
    m = modelIdx(k);
    mPos = modelPositions(k, :);
    ports = get_param(blocks{m}, 'PortHandles');

    % Inport Side: From -> Delay -> Model Port
    for p = 1:numel(ports.Inport)
        pHandle = ports.Inport(p);
        pY = get_param(pHandle, 'Position');
        pY = pY(2);

        lineH = get_param(pHandle, 'Line');
        if lineH == -1, continue; end
        srcH = get_param(lineH, 'SrcPortHandle');
        if srcH == -1, continue; end
        srcBlock = get_param(srcH, 'Parent');
        srcType = get_param(srcBlock, 'BlockType');

        if strcmp(srcType, 'UnitDelay')
            dRight = mPos(1) - fromModelGap;
            dLeft  = dRight - delayWidth;
            set_param(srcBlock, 'Position', [dLeft, pY - 10, dRight, pY + 10]);
            counts.TagBlocksAligned = counts.TagBlocksAligned + 1;

            dInports = get_param(srcBlock, 'PortHandles');
            dLine = get_param(dInports.Inport(1), 'Line');
            if dLine ~= -1
                dSrcH = get_param(dLine, 'SrcPortHandle');
                if dSrcH ~= -1
                    fBlock = get_param(dSrcH, 'Parent');
                    if strcmp(get_param(fBlock, 'BlockType'), 'From')
                        fRect = get_param(fBlock, 'Position');
                        fW = fRect(3) - fRect(1);
                        fRight = dLeft - delayGap;
                        set_param(fBlock, 'Position', [fRight - fW, pY - 10, fRight, pY + 10]);
                        counts.TagBlocksAligned = counts.TagBlocksAligned + 1;
                    end
                end
            end
        elseif strcmp(srcType, 'From')
            fRect = get_param(srcBlock, 'Position');
            fW = fRect(3) - fRect(1);
            fRight = mPos(1) - fromModelGap;
            set_param(srcBlock, 'Position', [fRight - fW, pY - 10, fRight, pY + 10]);
            counts.TagBlocksAligned = counts.TagBlocksAligned + 1;
        end
    end

    % Outport Side: Model Port -> Goto
    for p = 1:numel(ports.Outport)
        pHandle = ports.Outport(p);
        pY = get_param(pHandle, 'Position');
        pY = pY(2);

        lineH = get_param(pHandle, 'Line');
        if lineH == -1, continue; end
        dstHandles = get_param(lineH, 'DstPortHandle');
        for dIdx = 1:numel(dstHandles)
            if dstHandles(dIdx) == -1, continue; end
            dstBlock = get_param(dstHandles(dIdx), 'Parent');
            if strcmp(get_param(dstBlock, 'BlockType'), 'Goto')
                gRect = get_param(dstBlock, 'Position');
                gW = gRect(3) - gRect(1);
                gLeft = mPos(3) + gotoModelGap;
                set_param(dstBlock, 'Position', [gLeft, pY - 10, gLeft + gW, pY + 10]);
                counts.TagBlocksAligned = counts.TagBlocksAligned + 1;
            end
        end
    end
end

% 6. Align Root Inports (Far Left) and Root Outports (Far Right)
if options.AlignPortColumns
    for i = 1:numel(inportIdx)
        yCoord = modelBaseY + (i - 1) * 36;
        set_param(blocks{inportIdx(i)}, 'Position', [inportX, yCoord - 10, inportX + inportW, yCoord + 10]);
        counts.InportsAligned = counts.InportsAligned + 1;

        p = get_param(blocks{inportIdx(i)}, 'PortHandles');
        l = get_param(p.Outport(1), 'Line');
        if l ~= -1
            dsts = get_param(l, 'DstPortHandle');
            for d = 1:numel(dsts)
                if dsts(d) ~= -1 && strcmp(get_param(get_param(dsts(d), 'Parent'), 'BlockType'), 'Goto')
                    gBlock = get_param(dsts(d), 'Parent');
                    r = get_param(gBlock, 'Position');
                    gW = r(3) - r(1);
                    set_param(gBlock, 'Position', [rootGotoX, yCoord - 10, rootGotoX + gW, yCoord + 10]);
                end
            end
        end
    end

    lastModelRight = max(modelPositions(:, 3)) + gotoModelGap + 150;
    rootFromX = lastModelRight;
    rootOutportX = rootFromX + 180;

    for i = 1:numel(outportIdx)
        yCoord = modelBaseY + (i - 1) * 36;
        set_param(blocks{outportIdx(i)}, 'Position', [rootOutportX, yCoord - 10, rootOutportX + inportW, yCoord + 10]);
        counts.OutportsAligned = counts.OutportsAligned + 1;

        p = get_param(blocks{outportIdx(i)}, 'PortHandles');
        l = get_param(p.Inport(1), 'Line');
        if l ~= -1
            srcP = get_param(l, 'SrcPortHandle');
            if srcP ~= -1 && strcmp(get_param(get_param(srcP, 'Parent'), 'BlockType'), 'From')
                fBlock = get_param(srcP, 'Parent');
                r = get_param(fBlock, 'Position');
                fW = r(3) - r(1);
                set_param(fBlock, 'Position', [rootFromX - fW, yCoord - 10, rootFromX, yCoord + 10]);
            end
        end
    end
end

% 7. Force 100% Strict Orthogonal Line Routes across the entire diagram
if options.TidyLines
    set_param(topModel, 'SimulationCommand', 'update');
    counts = forceStrictOrthogonalLines(blocks, counts);
end
end

% =========================================================================
%  STRICT ORTHOGONAL ROUTER (0% Diagonals, 100% Right-Angles)
% =========================================================================
function counts = forceStrictOrthogonalLines(blocks, counts)
for b = 1:numel(blocks)
    try
        p = get_param(blocks{b}, 'PortHandles');
        for i = 1:numel(p.Outport)
            lineH = get_param(p.Outport(i), 'Line');
            if lineH ~= -1 && ishandle(lineH)
                sPort = get_param(lineH, 'SrcPortHandle');
                dPorts = get_param(lineH, 'DstPortHandle');
                
                if sPort ~= -1 && ~isempty(dPorts)
                    sPos = get_param(sPort, 'Position'); % [X, Y]
                    
                    for dIdx = 1:numel(dPorts)
                        dPort = dPorts(dIdx);
                        if dPort == -1, continue; end
                        dPos = get_param(dPort, 'Position'); % [X, Y]
                        
                        % CASE 1: Perfectly Aligned Y (Single Straight Horizontal Line)
                        if abs(sPos(2) - dPos(2)) <= 1.5 && sPos(1) < dPos(1)
                            points = [sPos(1), sPos(2); dPos(1), sPos(2)];
                            
                        % CASE 2: Forward Signal with Y-Offset (3-Segment Orthogonal Z-Bend)
                        elseif sPos(1) < dPos(1)
                            midX = round((sPos(1) + dPos(1)) / 2);
                            points = [ ...
                                sPos(1), sPos(2); ...
                                midX,    sPos(2); ...
                                midX,    dPos(2); ...
                                dPos(1), dPos(2)];
                            
                        % CASE 3: Backward/Feedback Signal (5-Segment Orthogonal U-Route Over Top)
                        else
                            clearY = min([sPos(2), dPos(2)]) - 40;
                            points = [ ...
                                sPos(1),       sPos(2); ...
                                sPos(1) + 15,  sPos(2); ...
                                sPos(1) + 15,  clearY;  ...
                                dPos(1) - 15,  clearY;  ...
                                dPos(1) - 15,  dPos(2); ...
                                dPos(1),       dPos(2)];
                        end
                        
                        try
                            set_param(lineH, 'Points', points);
                            counts.LinesStraightened = counts.LinesStraightened + 1;
                        catch
                            counts.LinesLeftAuto = counts.LinesLeftAuto + 1;
                        end
                    end
                end
            end
        end
    catch
    end
end
end

% =========================================================================
function counts = doConservativeLayout(sys, blocks, blockType, options, counts)
if options.TidyLines
    counts = forceStrictOrthogonalLines(blocks, counts);
end
end

% =========================================================================
function conns = snapshotConns(blocks)
conns = {};
for b = 1:numel(blocks)
    try
        p = get_param(blocks{b}, 'PortHandles');
        for i = 1:numel(p.Outport)
            l = get_param(p.Outport(i), 'Line');
            if l ~= -1
                d = get_param(l, 'DstPortHandle');
                for j = 1:numel(d)
                    if d(j) ~= -1
                        conns{end + 1} = sprintf('%d->%d', p.Outport(i), d(j)); %#ok<AGROW>
                    end
                end
            end
        end
    catch
    end
end
conns = sort(conns);
end