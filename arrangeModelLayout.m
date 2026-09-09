function result = arrangeModelLayout(systemName, options)
%ARRANGEMODELLAYOUT Arrange one level of a block diagram.

if nargin < 2 || isempty(options)
    options = struct();
end

% Fill top-level defaults
if ~isfield(options, 'FullRelayout'), options.FullRelayout = true; end
if ~isfield(options, 'Layout'), options.Layout = 'vertical'; end
if ~isfield(options, 'SameSize'), options.SameSize = true; end
if ~isfield(options, 'AlignPortColumns'), options.AlignPortColumns = true; end
if ~isfield(options, 'TidyLines'), options.TidyLines = true; end
if ~isfield(options, 'Spacing')
    options.Spacing = struct('FromModelGap', 100, 'ModelGotoGap', 100, ...
        'FromToDelayGap', 40, 'ModelToModelGap', 400);
else
    if ~isfield(options.Spacing, 'FromModelGap'), options.Spacing.FromModelGap = 100; end
    if ~isfield(options.Spacing, 'ModelGotoGap'), options.Spacing.ModelGotoGap = 100; end
    if ~isfield(options.Spacing, 'FromToDelayGap'), options.Spacing.FromToDelayGap = 40; end
    if ~isfield(options.Spacing, 'ModelToModelGap'), options.Spacing.ModelToModelGap = 400; end
end

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

% Initialize result with ALL fields that teamtools.m expects
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

    % Snapshot connections for safety verification
    origConns = snapshotConns(blocks);

    if options.FullRelayout
        stage = 'full grid re-layout';
        counts = doFullRelayout(sys, blocks, blockType, options, counts);
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
function counts = doFullRelayout(sys, blocks, blockType, options, counts)

isVert = ~strcmpi(options.Layout, 'horizontal');
modelIdx = find(strcmp(blockType, 'Model') | strcmp(blockType, 'SubSystem'));
inportIdx = find(strcmp(blockType, 'Inport'));
outportIdx = find(strcmp(blockType, 'Outport'));
fromIdx = find(strcmp(blockType, 'From'));
gotoIdx = find(strcmp(blockType, 'Goto'));
delayIdx = find(strcmp(blockType, 'UnitDelay'));

fromModelGap = options.Spacing.FromModelGap;
modelGotoGap = options.Spacing.ModelGotoGap;
fromToDelayGap = options.Spacing.FromToDelayGap;
modelToModelGap = options.Spacing.ModelToModelGap;

% Uniform model size
uW = 260; uH = 140;
for m = modelIdx
    r = get_param(blocks{m}, 'Position');
    p = get_param(blocks{m}, 'PortHandles');
    nP = max([numel(p.Inport), numel(p.Outport), 1]);
    uW = max(uW, r(3) - r(1));
    uH = max([uH, r(4) - r(2), (nP + 1) * 34]);
end

% Tag block width
tagW = 100;
for f = [fromIdx, gotoIdx]
    try
        tag = char(get_param(blocks{f}, 'GotoTag'));
        tagW = max(tagW, 8 * numel(tag) + 30);
    catch
    end
end

startX = 380; startY = 80;

% Place models
for k = 1:numel(modelIdx)
    m = modelIdx(k);
    if isVert
        mX = startX; mY = startY + (k - 1) * (uH + modelToModelGap);
    else
        mX = startX + (k - 1) * (uW + modelToModelGap); mY = startY;
    end
    set_param(blocks{m}, 'Position', [mX, mY, mX + uW, mY + uH]);
    counts.ModelsResized = counts.ModelsResized + 1;
end

topModel = strtok(sys, '/');
set_param(topModel, 'SimulationCommand', 'update');

% Align From/Goto/Delay to port heights
for k = 1:numel(modelIdx)
    m = modelIdx(k);
    mPos = get_param(blocks{m}, 'Position');
    ports = get_param(blocks{m}, 'PortHandles');

    for p = 1:numel(ports.Inport)
        pY = get_param(ports.Inport(p), 'Position');
        pY = pY(2);
        lineH = get_param(ports.Inport(p), 'Line');
        if lineH == -1, continue; end
        srcH = get_param(lineH, 'SrcPortHandle');
        if srcH == -1, continue; end
        srcBlock = get_param(srcH, 'Parent');
        srcType = get_param(srcBlock, 'BlockType');

        if strcmp(srcType, 'UnitDelay')
            dR = mPos(1) - fromModelGap;
            set_param(srcBlock, 'Position', [dR - 40, pY - 10, dR, pY + 10]);
            counts.TagBlocksAligned = counts.TagBlocksAligned + 1;
            counts.TagBlocksRespaced = counts.TagBlocksRespaced + 1;
            dPorts = get_param(srcBlock, 'PortHandles');
            dLine = get_param(dPorts.Inport(1), 'Line');
            if dLine ~= -1
                fH = get_param(dLine, 'SrcPortHandle');
                if fH ~= -1 && strcmp(get_param(fH, 'Parent'), 'From') || ...
                   (fH ~= -1 && strcmp(get_param(get_param(fH, 'Parent'), 'BlockType'), 'From'))
                    fBlock = get_param(fH, 'Parent');
                    fR = dR - 40 - fromToDelayGap;
                    set_param(fBlock, 'Position', [fR - tagW, pY - 10, fR, pY + 10]);
                    counts.TagBlocksAligned = counts.TagBlocksAligned + 1;
                    counts.FromGotoResized = counts.FromGotoResized + 1;
                end
            end
        elseif strcmp(srcType, 'From')
            fR = mPos(1) - fromModelGap;
            set_param(srcBlock, 'Position', [fR - tagW, pY - 10, fR, pY + 10]);
            counts.TagBlocksAligned = counts.TagBlocksAligned + 1;
            counts.FromGotoResized = counts.FromGotoResized + 1;
            counts.TagBlocksRespaced = counts.TagBlocksRespaced + 1;
        end
    end

    for p = 1:numel(ports.Outport)
        pY = get_param(ports.Outport(p), 'Position');
        pY = pY(2);
        lineH = get_param(ports.Outport(p), 'Line');
        if lineH == -1, continue; end
        dstH = get_param(lineH, 'DstPortHandle');
        for d = 1:numel(dstH)
            if dstH(d) == -1, continue; end
            dstBlock = get_param(dstH(d), 'Parent');
            if strcmp(get_param(dstBlock, 'BlockType'), 'Goto')
                gL = mPos(3) + modelGotoGap;
                set_param(dstBlock, 'Position', [gL, pY - 10, gL + tagW, pY + 10]);
                counts.TagBlocksAligned = counts.TagBlocksAligned + 1;
                counts.FromGotoResized = counts.FromGotoResized + 1;
                counts.TagBlocksRespaced = counts.TagBlocksRespaced + 1;
            end
        end
    end
end

% Align Inport/Outport columns
if options.AlignPortColumns
    inX = 50;
    outX = startX + numel(modelIdx) * (uW + modelToModelGap) + 200;
    for i = 1:numel(inportIdx)
        y = startY + (i - 1) * 50;
        set_param(blocks{inportIdx(i)}, 'Position', [inX, y, inX + 35, y + 20]);
        counts.InportsAligned = counts.InportsAligned + 1;
    end
    for i = 1:numel(outportIdx)
        y = startY + (i - 1) * 50;
        set_param(blocks{outportIdx(i)}, 'Position', [outX, y, outX + 35, y + 20]);
        counts.OutportsAligned = counts.OutportsAligned + 1;
    end
end

% Tidy lines
if options.TidyLines
    counts = tidyLines(blocks, counts);
end
end

% =========================================================================
function counts = doConservativeLayout(sys, blocks, blockType, options, counts)
if options.TidyLines
    counts = tidyLines(blocks, counts);
end
end

% =========================================================================
function counts = tidyLines(blocks, counts)
for b = 1:numel(blocks)
    try
        p = get_param(blocks{b}, 'PortHandles');
        for i = 1:numel(p.Outport)
            l = get_param(p.Outport(i), 'Line');
            if l ~= -1 && ishandle(l)
                sP = get_param(l, 'SrcPortHandle');
                dP = get_param(l, 'DstPortHandle');
                if sP ~= -1 && numel(dP) == 1 && dP ~= -1
                    s = get_param(sP, 'Position');
                    d = get_param(dP, 'Position');
                    if abs(s(2) - d(2)) <= 1 && s(1) < d(1)
                        try
                            set_param(l, 'Points', [s(1), s(2); d(1), d(2)]);
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