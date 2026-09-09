function result = arrangeModelLayout(systemName, options)
%ARRANGEMODELLAYOUT Direct Port Y-Locking Engine.
% Guarantees 100% flat, straight horizontal lines with ZERO vertical steps.

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
        stage = 'direct port y-locking layout';
        counts = doDirectPortYLockingRelayout(sys, blocks, blockType, options, counts);
    else
        stage = 'conservative layout';
        counts = doConservativeLayout(sys, blocks, blockType, options, counts);
    end

    % Verify connectivity
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
%  DIRECT PORT-TO-PORT Y-LOCKING ENGINE
% =========================================================================
function counts = doDirectPortYLockingRelayout(sys, blocks, blockType, options, counts)

modelIdx  = find(strcmp(blockType, 'Model') | strcmp(blockType, 'SubSystem'));
inportIdx = find(strcmp(blockType, 'Inport'));
outportIdx= find(strcmp(blockType, 'Outport'));
fromIdx   = find(strcmp(blockType, 'From'));
gotoIdx   = find(strcmp(blockType, 'Goto'));

nModels = numel(modelIdx);
if nModels == 0, return; end

% 1. Auto-size From & Goto blocks dynamically so text is NEVER truncated
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

% 3. Calculate Far-Left Clearance for Root Inports and Root Gotos
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

% 4. Position Model Reference Blocks Horizontally
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

    currentX = mX + mW + gotoModelGap +