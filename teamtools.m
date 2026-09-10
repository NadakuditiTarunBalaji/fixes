function teamtools
%TEAMTOOLS Simulink team tools in one simple app.
%
%   teamtools
%
% Opens a single window with two tabs:
%   1. Build Parent Model  - Generate a parent model from referenced
%      models with automatic dynamic layout, zero overlaps, and loop breaker.
%   2. Extract Attributes  - Collect attribute records from .m files
%      using a selected subsystem's port names as search tags.
%
% Requirements: MATLAB R2020a or newer with Simulink.

% ---- Make sure shared engines are reachable --------------------------
appFolder = fileparts(mfilename('fullpath'));
if ~isempty(appFolder)
    addpath(appFolder);
end

% ---- Session log: log.txt in current folder -------------------------
logPath = fullfile(pwd, 'log.txt');
prevDiaryOn = false;
prevDiaryFile = '';
try
    prevDiaryOn = strcmp(get(0, 'Diary'), 'on');
    if prevDiaryOn
        prevDiaryFile = char(get(0, 'DiaryFile'));
    end
    try
        delete(logPath);
    catch
    end
    fid = fopen(logPath, 'w');
    if fid ~= -1
        fclose(fid);
    end
    diary(logPath);
    fprintf(['=== Simulink Team Tools - session log started %s ', ...
        '(command window, warnings and errors all land in log.txt) ', ...
        '===\n'], char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
catch
end

try
    origCacheFolder = char(get_param(0, 'CacheFolder'));
catch
    origCacheFolder = '';
end

% ---- Shared state ---------------------------------------------------------
state = struct( ...
    'AvailableNames',    {{}}, ...
    'AvailableLabels',   {{}}, ...
    'AvailableFilter',   '', ...
    'Connections',       {{}}, ...
    'LastGeneratedModel', '', ...
    'ExtractOutput',     '');

% ---- Window ---------------------------------------------------------------
app = uifigure('Name', 'Simulink Team Tools', ...
    'Position', centeredPosition(1020, 700));
app.CloseRequestFcn = @onAppClose;

root = uigridlayout(app, [3 2]);
root.RowHeight = {30, '1x', 24};
root.ColumnWidth = {'1x', 110};
root.Padding = [14 8 14 6];
root.RowSpacing = 6;

headerLabel = uilabel(root, ...
    'Text', 'Simulink Team Tools', ...
    'FontSize', 15, 'FontWeight', 'bold');
headerLabel.Layout.Row = 1;
headerLabel.Layout.Column = 1;

% Clear All on top
clearAllTopBtn = uibutton(root, 'push', 'Text', 'Clear All', ...
    'FontSize', 11, 'ButtonPushedFcn', @clearAllData);
safeTooltip(clearAllTopBtn, 'Resets inputs across both tabs.');
clearAllTopBtn.Layout.Row = 1;
clearAllTopBtn.Layout.Column = 2;

statusLabel = uilabel(root, 'Text', 'Ready', 'FontColor', [0.35 0.35 0.35]);
statusLabel.Layout.Row = 3;
statusLabel.Layout.Column = 1;

tabs = uitabgroup(root);
tabs.Layout.Row = 2;
tabs.Layout.Column = 1;

tab1 = uitab(tabs, 'Title', 'Build Parent Model');
tab2 = uitab(tabs, 'Title', 'Extract Attributes');

% =========================================================================
%  TAB 1 - BUILD PARENT MODEL
% =========================================================================
g1 = uigridlayout(tab1, [18 6]);
g1.RowHeight = {24, 30, 26, '1.4x', 30, 24, 24, 26, 24, 24, 48, 20, 36, 24, 24, 36, 24, '1x'};
g1.ColumnWidth = {150, '1x', 105, 140, '1x', 105};
g1.Padding = [14 10 14 10];
g1.RowSpacing = 6;
g1.ColumnSpacing = 8;

hint1 = uilabel(g1, ...
    'Text', ['1) Choose models folder    2) Add models in order ' ...
    '   3) Preview    4) Generate (Auto-Layout Enabled)'], ...
    'FontAngle', 'italic', 'FontColor', [0.4 0.4 0.4]);
hint1.Layout.Row = 1;
hint1.Layout.Column = [1 6];

lblModelsFolder = uilabel(g1, 'Text', 'Models folder:', 'FontWeight', 'bold');
lblModelsFolder.Layout.Row = 2;
lblModelsFolder.Layout.Column = 1;

modelsFolderEdit = uieditfield(g1, 'text', ...
    'Value', getpref('teamtools', 'ModelsFolder', ''), ...
    'Placeholder', 'Folder containing .slx/.mdl models', ...
    'ValueChangedFcn', @onModelsFolderChanged);
modelsFolderEdit.Layout.Row = 2;
modelsFolderEdit.Layout.Column = [2 5];

browseModelsBtn = uibutton(g1, 'push', 'Text', 'Browse...', ...
    'FontSize', 11, 'ButtonPushedFcn', @browseModelsFolder);
browseModelsBtn.Layout.Row = 2;
browseModelsBtn.Layout.Column = 6;

lblAvail = uilabel(g1, 'Text', 'Available models:', 'FontWeight', 'bold');
lblAvail.Layout.Row = 3;
lblAvail.Layout.Column = 1;

filterEdit = uieditfield(g1, 'text', ...
    'Placeholder', 'Type to filter...', ...
    'ValueChangedFcn', @onAvailableFilterChanged);
filterEdit.Layout.Row = 3;
filterEdit.Layout.Column = 2;

lblSel = uilabel(g1, 'Text', 'Selected models (order matters):', 'FontWeight', 'bold');
lblSel.Layout.Row = 3;
lblSel.Layout.Column = [4 6];

availableList = uilistbox(g1);
availableList.Layout.Row = 4;
availableList.Layout.Column = [1 2];

btnGrid = uigridlayout(g1, [6 1]);
btnGrid.Layout.Row = 4;
btnGrid.Layout.Column = 3;
btnGrid.Padding = [2 2 2 2];
btnGrid.RowSpacing = 5;

addBtn = uibutton(btnGrid, 'push', 'Text', 'Add >>', 'FontSize', 11, 'ButtonPushedFcn', @addModel);
addAllBtn = uibutton(btnGrid, 'push', 'Text', 'Add All >>', 'FontSize', 11, 'ButtonPushedFcn', @addAllModels);
removeBtn = uibutton(btnGrid, 'push', 'Text', 'Remove', 'FontSize', 11, 'ButtonPushedFcn', @removeModel);
clearListBtn = uibutton(btnGrid, 'push', 'Text', 'Clear', 'FontSize', 11, 'ButtonPushedFcn', @clearSelectedModels);
upBtn = uibutton(btnGrid, 'push', 'Text', 'Move Up', 'FontSize', 11, 'ButtonPushedFcn', @moveModelUp);
downBtn = uibutton(btnGrid, 'push', 'Text', 'Move Down', 'FontSize', 11, 'ButtonPushedFcn', @moveModelDown);

selectedList = uilistbox(g1);
selectedList.Layout.Row = 4;
selectedList.Layout.Column = [4 6];

enableMultiSelect(availableList);
enableMultiSelect(selectedList);

lblName = uilabel(g1, 'Text', 'Generated model name:', 'FontWeight', 'bold');
lblName.Layout.Row = 5;
lblName.Layout.Column = 1;

nameEdit = uieditfield(g1, 'text', ...
    'Placeholder', 'GeneratedReferenceModel', ...
    'Value', getpref('teamtools', 'ModelName', ''));
nameEdit.Layout.Row = 5;
nameEdit.Layout.Column = [2 3];

lblSave = uilabel(g1, 'Text', 'Save in folder:', 'FontWeight', 'bold');
lblSave.Layout.Row = 5;
lblSave.Layout.Column = 4;

saveFolderEdit = uieditfield(g1, 'text', ...
    'Value', getpref('teamtools', 'SaveFolder', ''), ...
    'Placeholder', '(same as models folder)');
saveFolderEdit.Layout.Row = 5;
saveFolderEdit.Layout.Column = 5;

browseSaveBtn = uibutton(g1, 'push', 'Text', 'Browse...', ...
    'FontSize', 11, 'ButtonPushedFcn', @browseSaveFolder);
browseSaveBtn.Layout.Row = 5;
browseSaveBtn.Layout.Column = 6;

chkCase = uicheckbox(g1, 'Text', 'Match port names case-insensitively', 'Value', true);
chkCase.Layout.Row = 6;
chkCase.Layout.Column = [1 3];

chkBackup = uicheckbox(g1, 'Text', 'Backup existing model (.bak)', 'Value', true);
chkBackup.Layout.Row = 6;
chkBackup.Layout.Column = [4 6];

chkClose = uicheckbox(g1, 'Text', 'Close referenced models when done', 'Value', true);
chkClose.Layout.Row = 7;
chkClose.Layout.Column = [1 3];

chkWrap = uicheckbox(g1, 'Text', 'Create main subsystem (wrap all contents)', 'Value', true);
chkWrap.Layout.Row = 7;
chkWrap.Layout.Column = [4 6];

lblConnMethod = uilabel(g1, 'Text', 'Connect via:');
lblConnMethod.Layout.Row = 8;
lblConnMethod.Layout.Column = 1;

connMethodDrop = uidropdown(g1, 'Items', {'From/Goto blocks', 'Direct lines'}, 'Value', 'From/Goto blocks');
connMethodDrop.Layout.Row = 8;
connMethodDrop.Layout.Column = [2 3];

lblArrange = uilabel(g1, 'Text', 'Arrangement:');
lblArrange.Layout.Row = 8;
lblArrange.Layout.Column = 4;

layoutDrop = uidropdown(g1, 'Items', {'Horizontal (side by side)', 'Vertical (stacked)'}, 'Value', 'Horizontal (side by side)');
layoutDrop.Layout.Row = 8;
layoutDrop.Layout.Column = [5 6];

chkColor = uicheckbox(g1, 'Text', 'Color blocks by model', 'Value', true);
chkColor.Layout.Row = 9;
chkColor.Layout.Column = [1 3];

chkAutoDelay = uicheckbox(g1, 'Text', 'Auto Unit Delay on feedback signals', 'Value', true);
chkAutoDelay.Layout.Row = 9;
chkAutoDelay.Layout.Column = [4 6];

lblSpacing = uilabel(g1, 'Text', 'Block spacing:');
lblSpacing.Layout.Row = 10;
lblSpacing.Layout.Column = 1;

spacingEdit = uieditfield(g1, 'numeric', 'Value', 100, 'Limits', [55 1000], 'RoundFractionalValues', 'on');
spacingEdit.Layout.Row = 10;
spacingEdit.Layout.Column = 2;

lblSpacingHint = uilabel(g1, 'Text', 'points between new blocks (minimum 55)', 'FontAngle', 'italic', 'FontColor', [0.4 0.4 0.4]);
lblSpacingHint.Layout.Row = 10;
lblSpacingHint.Layout.Column = [3 6];

previewBtn = uibutton(g1, 'push', 'Text', 'Preview', 'FontSize', 12, 'ButtonPushedFcn', @doPreview);
previewBtn.Layout.Row = 11;
previewBtn.Layout.Column = [2 3];

generateBtn = uibutton(g1, 'push', 'Text', 'Generate', 'FontSize', 12, 'FontWeight', 'bold', 'ButtonPushedFcn', @doGenerate);
generateBtn.Layout.Row = 11;
generateBtn.Layout.Column = [4 5];

lblLoop = uilabel(g1, 'Text', ['Loop breaker - use when Simulink reports an algebraic loop:  ' ...
    '1) model name  2) Refresh list  3) pick connection  4) Insert Unit Delay'], 'FontWeight', 'bold');
lblLoop.Layout.Row = 12;
lblLoop.Layout.Column = [1 6];

connModelEdit = uieditfield(g1, 'text', 'Placeholder', 'model name (filled after Generate)');
connModelEdit.Layout.Row = 13;
connModelEdit.Layout.Column = [1 2];

refreshConnBtn = uibutton(g1, 'push', 'Text', 'Refresh list', 'FontSize', 11, 'ButtonPushedFcn', @refreshConnections);
refreshConnBtn.Layout.Row = 13;
refreshConnBtn.Layout.Column = 3;

connDropDown = uidropdown(g1, 'Items', {'(no connections yet)'});
connDropDown.Layout.Row = 13;
connDropDown.Layout.Column = [4 5];

insertDelayBtn = uibutton(g1, 'push', 'Text', 'Insert Unit Delay', 'FontSize', 11, 'Enable', 'off', 'ButtonPushedFcn', @insertDelay);
insertDelayBtn.Layout.Row = 13;
insertDelayBtn.Layout.Column = 6;

chkDelayFilter = uicheckbox(g1, 'Text', 'Show only connections that already have a Unit Delay', 'ValueChangedFcn', @refreshConnections);
chkDelayFilter.Layout.Row = 14;
chkDelayFilter.Layout.Column = [1 6];

chkShowAll = uicheckbox(g1, 'Text', 'Show all connections (with and without Unit Delay)', 'ValueChangedFcn', @refreshConnections);
chkShowAll.Layout.Row = 15;
chkShowAll.Layout.Column = [1 6];

lblSignals = uilabel(g1, 'Text', 'Subsystem signals:', 'FontWeight', 'bold');
lblSignals.Layout.Row = 16;
lblSignals.Layout.Column = [1 2];

configureSignalsBtn = uibutton(g1, 'push', 'Text', 'Configure Signals', 'FontSize', 11, 'ButtonPushedFcn', @doConfigureSignals);
configureSignalsBtn.Layout.Row = 16;
configureSignalsBtn.Layout.Column = [3 4];

lblSignalsHint = uilabel(g1, 'Text', 'select a Subsystem in the model, then press', 'FontAngle', 'italic', 'FontColor', [0.4 0.4 0.4]);
lblSignalsHint.Layout.Row = 16;
lblSignalsHint.Layout.Column = [5 6];

chkCfgInports = uicheckbox(g1, 'Text', 'Inports', 'Value', true);
chkCfgInports.Layout.Row = 17;
chkCfgInports.Layout.Column = [1 2];

chkCfgOutports = uicheckbox(g1, 'Text', 'Outports', 'Value', true);
chkCfgOutports.Layout.Row = 17;
chkCfgOutports.Layout.Column = [3 4];

chkCfgPropagation = uicheckbox(g1, 'Text', 'Propagation', 'Value', true);
chkCfgPropagation.Layout.Row = 17;
chkCfgPropagation.Layout.Column = 5;

chkCfgResolver = uicheckbox(g1, 'Text', 'Resolver', 'Value', true);
chkCfgResolver.Layout.Row = 17;
chkCfgResolver.Layout.Column = 6;

log1 = uitextarea(g1, 'Editable', 'off', 'Value', {'Ready. Choose a models folder to begin.'});
log1.Layout.Row = 18;
log1.Layout.Column = [1 6];

% =========================================================================
%  TAB 2 - EXTRACT ATTRIBUTES
% =========================================================================
g2 = uigridlayout(tab2, [11 6]);
g2.RowHeight = {24, 30, 30, 30, 30, 34, 30, 30, 20, 90, '1x'};
g2.ColumnWidth = {150, '1x', 105, 140, '1x', 105};
g2.Padding = [14 10 14 10];
g2.RowSpacing = 6;
g2.ColumnSpacing = 8;

hint2 = uilabel(g2, 'Text', ['1) Click subsystem in Simulink    2) Refresh    3) Choose folders    4) Extract'], ...
    'FontAngle', 'italic', 'FontColor', [0.4 0.4 0.4]);
hint2.Layout.Row = 1;
hint2.Layout.Column = [1 6];

lblSub = uilabel(g2, 'Text', 'Selected subsystem:', 'FontWeight', 'bold');
lblSub.Layout.Row = 2;
lblSub.Layout.Column = 1;

subsystemLabel = uilabel(g2, 'Text', '<no subsystem selected>', 'FontColor', [0.75 0 0]);
subsystemLabel.Layout.Row = 2;
subsystemLabel.Layout.Column = [2 5];

refreshSubBtn = uibutton(g2, 'push', 'Text', 'Refresh', 'FontSize', 11, 'ButtonPushedFcn', @refreshSubsystem);
refreshSubBtn.Layout.Row = 2;
refreshSubBtn.Layout.Column = 6;

lblPorts = uilabel(g2, 'Text', 'Ports to use as tags:', 'FontWeight', 'bold');
lblPorts.Layout.Row = 3;
lblPorts.Layout.Column = 1;

portDropDown = uidropdown(g2, 'Items', {'Inports', 'Outports', 'Both'}, 'Value', 'Both');
portDropDown.Layout.Row = 3;
portDropDown.Layout.Column = [2 3];

lblInfo = uilabel(g2, 'Text', 'File information:', 'FontWeight', 'bold');
lblInfo.Layout.Row = 3;
lblInfo.Layout.Column = 4;

infoDropDown = uidropdown(g2, 'Items', {'Header + source comments', 'Header only', 'Source comments only'}, 'Value', 'Header + source comments');
infoDropDown.Layout.Row = 3;
infoDropDown.Layout.Column = [5 6];

lblSearch = uilabel(g2, 'Text', 'Search folder:', 'FontWeight', 'bold');
lblSearch.Layout.Row = 4;
lblSearch.Layout.Column = 1;

searchEdit = uieditfield(g2, 'text', 'Value', getpref('teamtools', 'SearchFolder', ''), 'Placeholder', 'Parent folder containing .m files');
searchEdit.Layout.Row = 4;
searchEdit.Layout.Column = [2 5];

browseSearchBtn = uibutton(g2, 'push', 'Text', 'Browse...', 'FontSize', 11, 'ButtonPushedFcn', @browseSearchFolder);
browseSearchBtn.Layout.Row = 4;
browseSearchBtn.Layout.Column = 6;

lblDest = uilabel(g2, 'Text', 'Destination file:', 'FontWeight', 'bold');
lblDest.Layout.Row = 5;
lblDest.Layout.Column = 1;

destEdit = uieditfield(g2, 'text', 'Value', getpref('teamtools', 'OutputFile', ''), 'Placeholder', 'ExtractedAttributes.m');
destEdit.Layout.Row = 5;
destEdit.Layout.Column = [2 5];

browseDestBtn = uibutton(g2, 'push', 'Text', 'Browse...', 'FontSize', 11, 'ButtonPushedFcn', @browseOutputFile);
browseDestBtn.Layout.Row = 5;
browseDestBtn.Layout.Column = 6;

chkCase2 = uicheckbox(g2, 'Text', 'Case-insensitive matching', 'Value', true);
chkCase2.Layout.Row = 6;
chkCase2.Layout.Column = [1 3];

extractBtn = uibutton(g2, 'push', 'Text', 'Extract', 'FontSize', 11, 'FontWeight', 'bold', 'ButtonPushedFcn', @doExtract);
extractBtn.Layout.Row = 6;
extractBtn.Layout.Column = 4;

openOutputBtn = uibutton(g2, 'push', 'Text', 'Open Output', 'FontSize', 11, 'Enable', 'off', 'ButtonPushedFcn', @openOutputFile);
openOutputBtn.Layout.Row = 6;
openOutputBtn.Layout.Column = 5;

openFolderBtn = uibutton(g2, 'push', 'Text', 'Open Folder', 'FontSize', 11, 'Enable', 'off', 'ButtonPushedFcn', @openOutputFolder);
openFolderBtn.Layout.Row = 6;
openFolderBtn.Layout.Column = 6;

lblConvert = uilabel(g2, 'Text', 'convert_m_to_sldd:', 'FontWeight', 'bold');
lblConvert.Layout.Row = 7;
lblConvert.Layout.Column = 1;

convertPathEdit = uieditfield(g2, 'text', 'Value', getpref('teamtools', 'ConvertPath', ''), 'Placeholder', 'Path of convert_m_to_sldd.m');
convertPathEdit.Layout.Row = 7;
convertPathEdit.Layout.Column = [2 3];

browseConvertBtn = uibutton(g2, 'push', 'Text', 'Browse...', 'FontSize', 11, 'ButtonPushedFcn', @browseConvertPath);
browseConvertBtn.Layout.Row = 7;
browseConvertBtn.Layout.Column = 4;

convertBtn = uibutton(g2, 'push', 'Text', 'Convert to .sldd', 'FontSize', 11, 'FontWeight', 'bold', 'ButtonPushedFcn', @doConvertToSldd);
convertBtn.Layout.Row = 7;
convertBtn.Layout.Column = [5 6];

lblSlddDest = uilabel(g2, 'Text', 'Save .sldd in:', 'FontWeight', 'bold');
lblSlddDest.Layout.Row = 8;
lblSlddDest.Layout.Column = 1;

slddDestEdit = uieditfield(g2, 'text', 'Value', getpref('teamtools', 'SlddDestFolder', ''), 'Placeholder', 'Folder for .sldd (empty = .m folder)');
slddDestEdit.Layout.Row = 8;
slddDestEdit.Layout.Column = [2 3];

browseSlddDestBtn = uibutton(g2, 'push', 'Text', 'Browse...', 'FontSize', 11, 'ButtonPushedFcn', @browseSlddDest);
browseSlddDestBtn.Layout.Row = 8;
browseSlddDestBtn.Layout.Column = 4;

lblTags = uilabel(g2, 'Text', 'Tags that will be searched:', 'FontWeight', 'bold');
lblTags.Layout.Row = 9;
lblTags.Layout.Column = [1 6];

tagsList = uilistbox(g2);
tagsList.Layout.Row = 10;
tagsList.Layout.Column = [1 6];

log2 = uitextarea(g2, 'Editable', 'off', 'Value', {'Ready. Select a subsystem in Simulink and press Refresh.'});
log2.Layout.Row = 11;
log2.Layout.Column = [1 6];

% ---- Initial content -------------------------------------------------------
if isfolder(char(strtrim(modelsFolderEdit.Value)))
    refreshModelList();
else
    modelsFolderEdit.Value = '';
end

% =========================================================================
%  NESTED CALLBACKS
% =========================================================================
function setStatus(message)
statusLabel.Text = char(message);
drawnow limitrate;
end

function bringAppToFront()
try
    drawnow;
    figure(app);
catch
    try app.Visible = 'on'; catch, end
end
end

function onAppClose(~, ~)
try
    fprintf(['=== Simulink Team Tools - session log closed %s ===\n'], char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
catch
end
try
    diary('off');
    if prevDiaryOn, diary(prevDiaryFile); end
catch
end
try set_param(0, 'CacheFolder', origCacheFolder); catch, end
delete(app);
end

function browseModelsFolder(~, ~)
startFolder = pwd;
candidate = char(strtrim(modelsFolderEdit.Value));
if isfolder(candidate), startFolder = candidate; end
chosenFolder = uigetdir(startFolder, 'Select models folder');
bringAppToFront();
if isequal(chosenFolder, 0), return; end
modelsFolderEdit.Value = chosenFolder;
setpref('teamtools', 'ModelsFolder', chosenFolder);
if isempty(strtrim(saveFolderEdit.Value)), saveFolderEdit.Value = chosenFolder; end
refreshModelList();
end

function onModelsFolderChanged(~, ~)
candidate = char(strtrim(modelsFolderEdit.Value));
if isfolder(candidate)
    setpref('teamtools', 'ModelsFolder', candidate);
    refreshModelList();
elseif ~isempty(candidate)
    setStatus('That models folder does not exist.');
end
end

function refreshModelList()
folder = char(strtrim(modelsFolderEdit.Value));
if ~isfolder(folder), return; end
files = discoverModelFiles(folder);
if isempty(files)
    availableList.Items = {'(no .slx or .mdl files found)'};
    state.AvailableNames = {};
    state.AvailableLabels = {};
    setStatus(['No .slx or .mdl files found in: ' folder]);
    return;
end

labels = cell(numel(files), 1);
names = cell(numel(files), 1);
for fileIndex = 1:numel(files)
    [~, modelName] = fileparts(files(fileIndex).name);
    names{fileIndex} = modelName;
    relativeFolder = relativePart(files(fileIndex).folder, folder);
    if isempty(relativeFolder)
        labels{fileIndex} = modelName;
    else
        labels{fileIndex} = sprintf('%s  (%s)', modelName, relativeFolder);
    end
end

state.AvailableNames = names;
state.AvailableLabels = labels;
updateAvailableLabels();

if isempty(strtrim(state.AvailableFilter))
    setStatus(sprintf('%d model(s) found.', numel(files)));
else
    foundShown = numel(availableList.Items);
    if foundShown == 1 && strcmp(availableList.Items{1}, '(no matching models)')
        foundShown = 0;
    end
    setStatus(sprintf('%d model(s) found, %d match search filter.', numel(files), foundShown));
end
end

function updateAvailableLabels()
baseLabels = state.AvailableLabels;
if isempty(baseLabels), return; end

query = lower(strtrim(state.AvailableFilter));
if isempty(query)
    visibleMask = true(numel(baseLabels), 1);
else
    visibleMask = ~cellfun('isempty', strfind(lower(baseLabels), query));
end
baseLabels = baseLabels(visibleMask);
baseNames = state.AvailableNames(visibleMask);
if isempty(baseLabels)
    availableList.Items = {'(no matching models)'};
    return;
end

selectedNow = selectedList.Items;
marked = baseLabels;
for labelIndex = 1:numel(baseLabels)
    if any(strcmpi(selectedNow, baseNames{labelIndex}))
        marked{labelIndex} = [baseLabels{labelIndex} '  [added]'];
    end
end

if isequal(availableList.Items, marked), return; end

wasChar = ischar(availableList.Value);
currentSelection = asCell(availableList.Value);
currentBase = strrep(currentSelection, '  [added]', '');
selectedPositions = find(ismember(baseLabels, currentBase));

availableList.Items = marked;
if isempty(selectedPositions)
    try availableList.Value = marked{1}; catch, end
else
    setListSelection(availableList, marked(selectedPositions), wasChar);
end
end

function onAvailableFilterChanged(src, ~)
state.AvailableFilter = char(strtrim(src.Value));
if isempty(state.AvailableNames), return; end
updateAvailableLabels();
end

function addModel(~, ~)
selectedLabels = asCell(availableList.Value);
if isempty(selectedLabels)
    setStatus('Select one or more models in left list first.');
    return;
end
addModelsByLabel(selectedLabels);
end

function addAllModels(~, ~)
addModelsByLabel(availableList.Items);
end

function addModelsByLabel(labelsToAdd)
if isempty(state.AvailableNames), return; end
newNames = {};
skippedCount = 0;
for availIndex = 1:numel(state.AvailableLabels)
    baseLabel = state.AvailableLabels{availIndex};
    candidateName = state.AvailableNames{availIndex};
    alreadyAdded = any(strcmpi(selectedList.Items, candidateName));
    itemLabel = baseLabel;
    if alreadyAdded, itemLabel = [baseLabel '  [added]']; end
    if ~any(strcmp(labelsToAdd, itemLabel)), continue; end
    if alreadyAdded
        skippedCount = skippedCount + 1;
    else
        newNames{end + 1} = candidateName; %#ok<AGROW>
    end
end

if isempty(newNames), return; end
wasChar = ischar(selectedList.Value);
selectedList.Items = [selectedList.Items, newNames];
setListSelection(selectedList, newNames, wasChar);
updateAvailableLabels();
end

function removeModel(~, ~)
if isempty(selectedList.Items), return; end
selectedValues = asCell(selectedList.Value);
if isempty(selectedValues), return; end
items = selectedList.Items;
items = items(~ismember(items, selectedValues));
selectedList.Items = items;
if ~isempty(items), selectedList.Value = items{1}; end
updateAvailableLabels();
end

function clearSelectedModels(~, ~)
selectedList.Items = {};
updateAvailableLabels();
end

function clearAllData(~, ~)
filterEdit.Value = '';
state.AvailableFilter = '';
state.AvailableNames = {};
state.AvailableLabels = {};
selectedList.Items = {};
updateAvailableLabels();
modelsFolderEdit.Value = '';
availableList.Items = {};
try availableList.Value = ''; catch, end
nameEdit.Value = '';
saveFolderEdit.Value = '';
chkCase.Value = true;
chkBackup.Value = true;
chkClose.Value = true;
chkWrap.Value = true;
connMethodDrop.Value = 'From/Goto blocks';
layoutDrop.Value = 'Horizontal (side by side)';
chkColor.Value = true;
chkAutoDelay.Value = true;
spacingEdit.Value = 100;

connModelEdit.Value = '';
chkDelayFilter.Value = false;
chkShowAll.Value = false;
state.Connections = {};
state.LastGeneratedModel = '';
try
    connDropDown.Items = {'(no connections yet)'};
    connDropDown.Value = '(no connections yet)';
catch
end
insertDelayBtn.Enable = 'off';

subsystemLabel.Text = '<no subsystem selected>';
subsystemLabel.FontColor = [0.75 0 0];
searchEdit.Value = '';
destEdit.Value = '';
convertPathEdit.Value = '';
slddDestEdit.Value = '';
tagsList.Items = {};

logTo(log1, 'All inputs cleared.');
setStatus('All inputs cleared.');
end

function moveModelUp(~, ~), moveModel(-1); end
function moveModelDown(~, ~), moveModel(1); end

function moveModel(direction)
if isempty(selectedList.Items), return; end
selectedValues = asCell(selectedList.Value);
if isempty(selectedValues), return; end
items = selectedList.Items;
selectedMask = ismember(items, selectedValues);
wasChar = ischar(selectedList.Value);

if direction < 0, scanOrder = 1:numel(items); else, scanOrder = numel(items):-1:1; end

for k = scanOrder
    if ~selectedMask(k), continue; end
    targetIndex = k + direction;
    if targetIndex < 1 || targetIndex > numel(items) || selectedMask(targetIndex), continue; end
    tmp = items{k}; items{k} = items{targetIndex}; items{targetIndex} = tmp;
    tmpMask = selectedMask(k); selectedMask(k) = selectedMask(targetIndex); selectedMask(targetIndex) = tmpMask;
end

selectedList.Items = items;
setListSelection(selectedList, selectedValues, wasChar);
end

function browseSaveFolder(~, ~)
startFolder = pwd;
candidate = char(strtrim(modelsFolderEdit.Value));
if isfolder(candidate), startFolder = candidate; end
candidate = char(strtrim(saveFolderEdit.Value));
if isfolder(candidate), startFolder = candidate; end
chosenFolder = uigetdir(startFolder, 'Select save folder');
bringAppToFront();
if isequal(chosenFolder, 0), return; end
saveFolderEdit.Value = chosenFolder;
setpref('teamtools', 'SaveFolder', chosenFolder);
end

function s = integrationStyle()
s = struct();
if strcmp(connMethodDrop.Value, 'Direct lines'), s.ConnectionMethod = 'lines'; else, s.ConnectionMethod = 'fromgoto'; end
if startsWith(layoutDrop.Value, 'Horizontal'), s.Layout = 'horizontal'; else, s.Layout = 'vertical'; end
s.ColorBlocks = logical(chkColor.Value);
s.AutoDelayFeedback = logical(chkAutoDelay.Value);
s.BlockSpacing = spacingPoints();
end

function spacing = spacingPoints()
try value = double(spacingEdit.Value); catch, value = 100; end
if isnan(value) || value < 55, value = 55; end
spacing = round(value);
end

function [folder, models, modelName, saveFolder] = validateTab1()
folder = char(strtrim(modelsFolderEdit.Value));
if ~isfolder(folder)
    notify(app, 'Choose valid models folder first.', 'Missing folder', 'warning');
    folder = ''; return;
end
models = selectedList.Items;
if isempty(models)
    notify(app, 'Add at least one model to selected list.', 'No models', 'warning');
    models = {}; return;
end
modelName = char(strtrim(nameEdit.Value));
if isempty(modelName)
    modelName = 'GeneratedReferenceModel';
    nameEdit.Value = modelName;
end
modelName = matlab.lang.makeValidName(modelName, 'ReplacementStyle', 'underscore');
saveFolder = char(strtrim(saveFolderEdit.Value));
if isempty(saveFolder)
    saveFolder = folder;
    saveFolderEdit.Value = folder;
end
if ~isfolder(saveFolder)
    notify(app, 'Save folder path does not exist.', 'Invalid folder', 'warning');
    folder = ''; return;
end
end

function doPreview(~, ~)
[folder, models, modelName, saveFolder] = validateTab1();
if isempty(folder) || isempty(models), return; end

styleOpts = integrationStyle();
options = struct( ...
    'PreviewOnly',          true, ...
    'CaseInsensitiveMatch', chkCase.Value, ...
    'OutputFolder',         saveFolder, ...
    'ConnectionMethod',     styleOpts.ConnectionMethod, ...
    'Layout',               styleOpts.Layout, ...
    'ColorBlocks',          styleOpts.ColorBlocks, ...
    'AutoDelayFeedback',    styleOpts.AutoDelayFeedback, ...
    'BlockSpacing',         styleOpts.BlockSpacing, ...
    'ConfigParameters',     {{'UseDivisionForNetSlopeComputation'}});

setStatus('Preparing preview...');
previewBtn.Enable = 'off';
p = makeProgress(app, 'Preparing preview');
try
    options.ProgressFcn = @(fraction, message) p.set(fraction, message);
    options.CancelRequestedFcn = @() p.cancelled();
    result = buildParentModelCore(folder, models, modelName, options);
    p.close();
catch previewError
    p.close();
    previewBtn.Enable = 'on';
    setStatus('Preview failed.');
    logTo(log1, ['ERROR: ' errorDetails(previewError)]);
    notify(app, errorDetails(previewError), 'Preview failed', 'error');
    return;
end
previewBtn.Enable = 'on';
logMany(log1, renderPlanLines(result));
setStatus('Preview complete.');
end

function doGenerate(~, ~)
[folder, models, modelName, saveFolder] = validateTab1();
if isempty(folder) || isempty(models), return; end

targetFile = fullfile(saveFolder, [modelName '.slx']);
overwrite = false;
if isfile(targetFile)
    doOverwrite = confirmDialog(app, sprintf('Overwrite existing model %s?', targetFile), ...
        'Overwrite model?', 'Yes, overwrite', 'Cancel');
    if ~doOverwrite, setStatus('Generation cancelled.'); return; end
    overwrite = true;
end

styleOpts = integrationStyle();
options = struct( ...
    'PreviewOnly',          false, ...
    'Overwrite',            overwrite, ...
    'BackupExisting',       chkBackup.Value, ...
    'CaseInsensitiveMatch', chkCase.Value, ...
    'CloseReferencedModels', chkClose.Value, ...
    'WrapInSubsystem',      chkWrap.Value, ...
    'OutputFolder',         saveFolder, ...
    'ConnectionMethod',     styleOpts.ConnectionMethod, ...
    'Layout',               styleOpts.Layout, ...
    'ColorBlocks',          styleOpts.ColorBlocks, ...
    'AutoDelayFeedback',    styleOpts.AutoDelayFeedback, ...
    'BlockSpacing',         styleOpts.BlockSpacing, ...
    'ConfigParameters',     {{'UseDivisionForNetSlopeComputation'}});

setStatus('Generating & Auto-Arranging...');
generateBtn.Enable = 'off'; previewBtn.Enable = 'off';
p = makeProgress(app, 'Generating parent model');
try
    options.ProgressFcn = @(fraction, message) p.set(fraction, message);
    options.CancelRequestedFcn = @() p.cancelled();
    result = buildParentModelCore(folder, models, modelName, options);
    p.close();
catch generateError
    p.close(); generateBtn.Enable = 'on'; previewBtn.Enable = 'on';
    setStatus('Generation failed.');
    logTo(log1, ['ERROR: ' errorDetails(generateError)]);
    notify(app, errorDetails(generateError), 'Generation failed', 'error');
    return;
end
generateBtn.Enable = 'on'; previewBtn.Enable = 'on';

if result.Cancelled
    setStatus('Generation cancelled.'); return;
end

state.LastGeneratedModel = result.TargetModel;
setpref('teamtools', 'GeneratedModel', result.TargetModel);
connModelEdit.Value = result.TargetModel;
destEdit.Value = [result.TargetModel, '_data.m'];

refreshConnections();
setStatus('Model generated and auto-arranged successfully.');
notify(app, sprintf('Model generated successfully with automatic dynamic layout:\n%s', result.OutputFile), ...
    'Generation complete', 'success');
end

function refreshConnections(~, ~)
modelName = char(strtrim(connModelEdit.Value));
if isempty(modelName), modelName = state.LastGeneratedModel; end
if isempty(modelName), setStatus('Enter model name first.'); return; end
if ~bdIsLoaded(modelName)
    insertDelayBtn.Enable = 'off';
    try connDropDown.Items = {'(model is not open)'}; catch, end
    setStatus(sprintf('Model "%s" is not open.', modelName));
    return;
end

try
    [connections, connStats] = listModelConnections(modelName);
catch listError
    insertDelayBtn.Enable = 'off';
    logTo(log1, ['ERROR: ' errorDetails(listError)]);
    return;
end

if isempty(connections)
    state.Connections = {};
    try connDropDown.Items = {'(no model-to-model connections found)'}; catch, end
    insertDelayBtn.Enable = 'off';
    setStatus('No backward connections found.');
    return;
end

state.Connections = num2cell(connections);
delayedMask = cellfun(@(c) isfield(c, 'AlreadyDelayed') && c.AlreadyDelayed, state.Connections);
if chkShowAll.Value
    shownConnections = state.Connections;
elseif chkDelayFilter.Value
    shownConnections = state.Connections(delayedMask);
else
    shownConnections = state.Connections(~delayedMask);
end

if isempty(shownConnections)
    insertDelayBtn.Enable = 'off';
    setStatus('All backward connections already have Unit Delays.');
    return;
end

labels = cellfun(@(c) c.Label, shownConnections, 'UniformOutput', false);
try connDropDown.Items = labels; connDropDown.Value = labels{1}; catch, end
insertDelayBtn.Enable = 'on';
setStatus(sprintf('%d connection(s) listed - pick one.', numel(labels)));
end

function insertDelay(~, ~)
if isempty(state.Connections), return; end
selLabel = char(connDropDown.Value);
selIndex = 0;
for cIndex = 1:numel(state.Connections)
    if strcmp(state.Connections{cIndex}.Label, selLabel)
        selIndex = cIndex; break;
    end
end
if selIndex == 0, return; end
connection = state.Connections{selIndex};

try
    result = insertUnitDelayOnBranch(connection.System, ...
        connection.SrcBlockPath, connection.SrcPortIndex, ...
        connection.DstBlockPath, connection.DstPortIndex, ...
        struct('BlockSpacing', spacingPoints()));
    save_system(strtok(connection.System, '/'));
    logTo(log1, result.Message);
    refreshConnections();
catch delayError
    logTo(log1, ['ERROR: ' errorDetails(delayError)]);
end
end

function doConfigureSignals(~, ~)
try
    signalReport = configureSubsystemSignals(struct( ...
        'ProcessInports',  logical(chkCfgInports.Value), ...
        'ProcessOutports', logical(chkCfgOutports.Value), ...
        'ShowPropagation', logical(chkCfgPropagation.Value), ...
        'MustResolve',     logical(chkCfgResolver.Value)));
catch cfgError
    logTo(log1, ['ERROR: ' errorDetails(cfgError)]);
    return;
end
logTo(log1, 'Subsystem signals configured successfully.');
end

% =========================================================================
%  TAB 2 CALLBACKS
% =========================================================================
function refreshSubsystem(~, ~)
try
    ports = getSubsystemPorts();
    subsystemLabel.Text = ports.Path;
    subsystemLabel.FontColor = [0 0 0];
    items = {};
    for portIndex = 1:numel(ports.InportNames), items{end + 1} = ['IN   ' ports.InportNames{portIndex}]; end %#ok<AGROW>
    for portIndex = 1:numel(ports.OutportNames), items{end + 1} = ['OUT  ' ports.OutportNames{portIndex}]; end %#ok<AGROW>
    tagsList.Items = items;
    setStatus('Subsystem selected.');
catch selectionError
    subsystemLabel.Text = '<no subsystem selected>';
    subsystemLabel.FontColor = [0.75 0 0];
    tagsList.Items = {};
end
end

function browseSearchFolder(~, ~)
chosenFolder = uigetdir(pwd, 'Select search folder');
bringAppToFront();
if isequal(chosenFolder, 0), return; end
searchEdit.Value = chosenFolder;
end

function browseOutputFile(~, ~)
[name, folder] = uiputfile({'*.m', 'MATLAB files (*.m)'}, 'Select destination .m file');
bringAppToFront();
if isequal(name, 0) || isequal(folder, 0), return; end
destEdit.Value = fullfile(folder, name);
end

function doExtract(~, ~)
try ports = getSubsystemPorts(); catch, return; end
searchFolder = char(strtrim(searchEdit.Value));
if ~isfolder(searchFolder), return; end
outputFile = char(strtrim(destEdit.Value));
if isempty(outputFile), return; end

options = struct('PortChoice', portDropDown.Value, 'CaseInsensitive', chkCase2.Value);
p = makeProgress(app, 'Extracting attributes');
try
    result = extractAttributesCore(ports.Handle, searchFolder, outputFile, options);
    p.close();
    openOutputBtn.Enable = 'on'; openFolderBtn.Enable = 'on';
    state.ExtractOutput = result.OutputFile;
    setStatus('Extraction complete.');
catch extractError
    p.close();
    logTo(log2, ['ERROR: ' errorDetails(extractError)]);
end
end

function openOutputFile(~, ~)
if ~isempty(state.ExtractOutput), open(state.ExtractOutput); end
end

function openOutputFolder(~, ~)
if ~isempty(state.ExtractOutput), open(fileparts(state.ExtractOutput)); end
end

function browseConvertPath(~, ~)
[f, p] = uigetfile('*.m', 'Pick convert_m_to_sldd.m');
bringAppToFront();
if ~isequal(f, 0), convertPathEdit.Value = fullfile(p, f); end
end

function browseSlddDest(~, ~)
f = uigetdir(pwd, 'Pick .sldd destination folder');
bringAppToFront();
if ~isequal(f, 0), slddDestEdit.Value = f; end
end

function doConvertToSldd(~, ~)
convertPath = char(strtrim(convertPathEdit.Value));
if isempty(convertPath), return; end
mFile = state.ExtractOutput;
if isempty(mFile) || ~isfile(mFile), return; end
addpath(fileparts(convertPath));
try
    convert_m_to_sldd();
    setStatus('Converted to .sldd successfully.');
catch convertError
    logTo(log2, ['ERROR: ' errorDetails(convertError)]);
end
end

% Embedded getSubsystemPorts Helper
function ports = getSubsystemPorts(subsystemHandle)
if nargin < 1 || isempty(subsystemHandle), subsystemHandle = gcbh; end
if isempty(subsystemHandle) || subsystemHandle <= 0
    error('getSubsystemPorts:NoSelection', 'Select a subsystem in Simulink first.');
end
commonOptions = {'LookUnderMasks', 'on', 'FollowLinks', 'on', 'SearchDepth', 1};
inportHandles = find_system(subsystemHandle, commonOptions{:}, 'BlockType', 'Inport');
outportHandles = find_system(subsystemHandle, commonOptions{:}, 'BlockType', 'Outport');
ports = struct('Handle', double(subsystemHandle), 'Path', getfullname(subsystemHandle), ...
    'InportNames', {normSubNames(inportHandles)}, 'OutportNames', {normSubNames(outportHandles)});
end

function names = normSubNames(handles)
if isempty(handles), names = {}; return; end
names = get_param(handles, 'Name');
if ischar(names), names = {names}; end
names = unique(cellfun(@strtrim, names(~cellfun('isempty', names)), 'UniformOutput', false), 'stable');
names = names(:).';
end

end

% =========================================================================
%  LOCAL FUNCTIONS
% =========================================================================
function p = makeProgress(appFigure, title)
try
    dialogHandle = uiprogressdlg(appFigure, 'Title', title, 'Message', 'Preparing...', 'Indeterminate', 'on', 'Cancelable', 'on');
catch
    dialogHandle = uiprogressdlg(appFigure, 'Title', title, 'Message', 'Preparing...', 'Indeterminate', 'on');
end
p.set = @(f, m) progressSet(dialogHandle, f, m);
p.cancelled = @() progressCancelled(dialogHandle);
p.close = @() progressClose(dialogHandle);
end

function progressSet(dh, f, m)
if isvalid(dh), try dh.Indeterminate = 'off'; dh.Value = f; dh.Message = char(m); catch, end; drawnow limitrate; end
end

function tf = progressCancelled(dh)
tf = false;
if isvalid(dh) && isprop(dh, 'CancelRequested'), tf = logical(dh.CancelRequested); end
end

function progressClose(dh)
if ~isempty(dh) && isvalid(dh), close(dh); end
end

function notify(appFigure, message, title, icon)
try uialert(appFigure, char(message), title, 'Icon', icon); catch, msgbox(char(message), title); end
end

function safeTooltip(component, text)
try component.Tooltip = char(text); catch, end
end

function tf = confirmDialog(appFigure, message, title, okLabel, cancelLabel)
tf = false;
try
    tf = dialogChoice(uiconfirm(appFigure, char(message), char(title), 'Buttons', {okLabel, cancelLabel}, ...
        'DefaultButton', cancelLabel, 'CancelButton', cancelLabel, 'Icon', 'warning'), okLabel);
    return;
catch
end
end

function tf = dialogChoice(answer, okLabel)
if isstruct(answer) && isfield(answer, 'SelectedButton')
    tf = strcmp(char(answer.SelectedButton), char(okLabel));
elseif ischar(answer)
    tf = strcmp(answer, char(okLabel));
else
    tf = false;
end
end

function details = errorDetails(err)
details = strtrim(char(err.message));
for groupIndex = 1:numel(err.cause)
    causeGroup = err.cause{groupIndex};
    for causeIndex = 1:numel(causeGroup)
        causeText = strtrim(char(causeGroup(causeIndex).message));
        if ~isempty(causeText), details = [details newline '   caused by: ' causeText]; end
    end
end
details = regexprep(details, '<a[^>]*>\s*([^<]*?)\s*</a>', '$1');
end

function values = asCell(value)
if isempty(value), values = {}; elseif ischar(value), values = {value}; else, values = value(:)'; end
end

function enableMultiSelect(listBox)
try listBox.Multiselect = 'on'; catch, end
end

function setListSelection(list, values, wasChar)
if isempty(values), return; end
if wasChar, list.Value = values{1}; else, try list.Value = values; catch, list.Value = values{1}; end; end
end

function logTo(area, message)
stamp = char(datetime('now', 'Format', 'HH:mm:ss'));
text = [stamp, '  ', char(message)];
try fprintf('%s\n', text); catch, end
lines = area.Value; if ischar(lines), lines = {lines}; end
lines = [lines; {text}]; if numel(lines) > 500, lines = lines(end - 499:end); end
area.Value = lines; drawnow limitrate;
end

function logMany(area, newLines)
if isempty(newLines), return; end
lines = area.Value; if ischar(lines), lines = {lines}; end
stamp = char(datetime('now', 'Format', 'HH:mm:ss'));
lines = [lines; {['---- ', stamp, ' ----']}; newLines(:)];
if numel(lines) > 500, lines = lines(end - 499:end); end
area.Value = lines; drawnow limitrate;
end

function files = discoverModelFiles(folder)
slxFiles = dir(fullfile(folder, '**', '*.slx'));
mdlFiles = dir(fullfile(folder, '**', '*.mdl'));
files = [slxFiles; mdlFiles];
end

function relativePart = relativePart(fullPath, rootFolder)
rootWithSeparator = [char(rootFolder) filesep];
if strncmpi(fullPath, rootWithSeparator, numel(rootWithSeparator))
    relativePart = fullPath(numel(rootWithSeparator) + 1:end);
    cutAt = strfind(relativePart, filesep);
    if ~isempty(cutAt), relativePart = relativePart(1:cutAt(end) - 1); end
else
    relativePart = '';
end
end

function lines = renderPlanLines(result)
lines = {};
lines{end + 1} = '================ PREVIEW ================';
lines{end + 1} = sprintf('Generated model: %s', result.TargetModel);
for modelIndex = 1:numel(result.Models)
    model = result.Models(modelIndex);
    lines{end + 1} = sprintf('  %d. %-20s %d in, %d out', modelIndex, model.Name, numel(model.InputNames), numel(model.OutputNames));
end
lines{end + 1} = '==========================================';
end

function position = centeredPosition(width, height)
screenSize = get(groot, 'ScreenSize');
left = max(1, round((screenSize(3) - width) / 2));
bottom = max(1, round((screenSize(4) - height) / 2));
position = [left bottom width height];
end

% =========================================================================
%  CORE IMPLEMENTATION ENGINE
% =========================================================================

function result = buildParentModelCore(folder, models, modelName, options)
    result = struct('Cancelled', false, 'TargetModel', modelName, ...
                    'OutputFile', '', 'Models', struct('Name', {}, 'InputNames', {}, 'OutputNames', {}));

    allFiles = discoverModelFiles(folder);
    modelPaths = struct();
    for i = 1:numel(models)
        mName = models{i};
        found = false;
        for j = 1:numel(allFiles)
            [~, fName] = fileparts(allFiles(j).name);
            if strcmpi(fName, mName)
                modelPaths.(mName) = fullfile(allFiles(j).folder, allFiles(j).name);
                found = true;
                break;
            end
        end
        if ~found
            error('Model "%s" not found in search directory.', mName);
        end
    end

    modelsMeta = [];
    for i = 1:numel(models)
        mName = models{i};
        mPath = modelPaths.(mName);
        
        wasLoaded = bdIsLoaded(mName);
        if ~wasLoaded
            load_system(mPath);
        end
        
        inBlks = find_system(mName, 'SearchDepth', 1, 'BlockType', 'Inport');
        if ~isempty(inBlks)
            portsNum = cellfun(@(x) str2double(get_param(x, 'Port')), inBlks);
            [~, idx] = sort(portsNum);
            inBlks = inBlks(idx);
            inNames = get_param(inBlks, 'Name');
            if ischar(inNames), inNames = {inNames}; end
        else
            inNames = {};
        end
        
        outBlks = find_system(mName, 'SearchDepth', 1, 'BlockType', 'Outport');
        if ~isempty(outBlks)
            portsNum = cellfun(@(x) str2double(get_param(x, 'Port')), outBlks);
            [~, idx] = sort(portsNum);
            outBlks = outBlks(idx);
            outNames = get_param(outBlks, 'Name');
            if ischar(outNames), outNames = {outNames}; end
        else
            outNames = {};
        end
        
        meta = struct('Name', mName, 'Path', mPath, 'InputNames', {inNames}, 'OutputNames', {outNames}, 'WasLoaded', wasLoaded);
        modelsMeta = [modelsMeta; meta]; %#ok<AGROW>
    end
    
    result.Models = modelsMeta;
    
    if options.PreviewOnly
        return;
    end
    
    targetFile = fullfile(options.OutputFolder, [modelName '.slx']);
    
    if bdIsLoaded(modelName)
        close_system(modelName, 0);
    end
    if isfile(targetFile) && options.BackupExisting
        [p, n, e] = fileparts(targetFile);
        copyfile(targetFile, fullfile(p, [n '.bak']));
    end
    
    new_system(modelName);
    open_system(modelName);
    
    set_param(modelName, 'Solver', 'FixedStepDiscrete');
    
    blockHandles = [];
    refBlockPaths = cell(numel(models), 1);
    
    spacing = options.BlockSpacing;
    x = 150; y = 150;
    
    palette = {'LightBlue', 'Green', 'Yellow', 'Cyan', 'Orange', 'Magenta', 'Gray'};
    
    for i = 1:numel(models)
        mName = models{i};
        numIn = numel(modelsMeta(i).InputNames);
        numOut = numel(modelsMeta(i).OutputNames);
        blockHeight = max(80, max(numIn, numOut) * 35);
        blockWidth = 160;
        
        pos = [x, y, x + blockWidth, y + blockHeight];
        blockPath = [modelName '/' mName];
        h = add_block('simulink/Ports & Subsystems/Model Reference', blockPath, ...
            'Position', pos, 'MakeNameUnique', 'on');
        blockHandles = [blockHandles; h]; %#ok<AGROW>
        
        actualBlockName = get_param(h, 'Name');
        refBlockPaths{i} = [modelName '/' actualBlockName];
        
        set_param(h, 'ModelName', mName);
        
        if options.ColorBlocks
            color = palette{mod(i-1, numel(palette)) + 1};
            set_param(h, 'BackgroundColor', color);
        end
        
        if strcmp(options.Layout, 'horizontal')
            x = x + blockWidth + spacing;
        else
            y = y + blockHeight + spacing;
        end
    end
    
    connections = {};
    for dstIdx = 1:numel(models)
        dstMeta = modelsMeta(dstIdx);
        dstBlock = refBlockPaths{dstIdx};
        
        for portInIdx = 1:numel(dstMeta.InputNames)
            inName = dstMeta.InputNames{portInIdx};
            matched = false;
            
            for srcIdx = 1:numel(models)
                if srcIdx == dstIdx, continue; end
                srcMeta = modelsMeta(srcIdx);
                srcBlock = refBlockPaths{srcIdx};
                
                for portOutIdx = 1:numel(srcMeta.OutputNames)
                    outName = srcMeta.OutputNames{portOutIdx};
                    
                    if options.CaseInsensitiveMatch
                        isMatch = strcmpi(inName, outName);
                    else
                        isMatch = strcmp(inName, outName);
                    end
                    
                    if isMatch
                        connections{end+1} = struct(...
                            'SrcBlock', srcBlock, 'SrcIdx', srcIdx, 'SrcPort', portOutIdx, ...
                            'DstBlock', dstBlock, 'DstIdx', dstIdx, 'DstPort', portInIdx, ...
                            'SignalName', outName); %#ok<AGROW>
                        matched = true;
                        break;
                    end
                end
                if matched, break; end
            end
        end
    end
    
    isLines = strcmp(options.ConnectionMethod, 'lines');
    gotoTags = struct();
    
    for i = 1:numel(connections)
        conn = connections{i};
        isFeedback = (conn.SrcIdx >= conn.DstIdx);
        
        if isLines
            if options.AutoDelayFeedback && isFeedback
                srcPos = get_param(conn.SrcBlock, 'Position');
                dstPos = get_param(conn.DstBlock, 'Position');
                midY = round((srcPos(2) + dstPos(4)) / 2);
                midX = round((srcPos(1) + dstPos(3)) / 2);
                
                delayName = [modelName '/Delay_' conn.SignalName];
                hDelay = add_block('simulink/Discrete/Unit Delay', delayName, ...
                    'Position', [midX - 15, midY - 15, midX + 15, midY + 15], 'MakeNameUnique', 'on');
                blockHandles = [blockHandles; hDelay]; %#ok<AGROW>
                
                actualDelayName = get_param(hDelay, 'Name');
                
                add_line(modelName, [get_param(conn.SrcBlock, 'Name') '/' num2str(conn.SrcPort)], ...
                    [actualDelayName '/1'], 'autorouting', 'on');
                add_line(modelName, [actualDelayName '/1'], ...
                    [get_param(conn.DstBlock, 'Name') '/' num2str(conn.DstPort)], 'autorouting', 'on');
            else
                add_line(modelName, [get_param(conn.SrcBlock, 'Name') '/' num2str(conn.SrcPort)], ...
                    [get_param(conn.DstBlock, 'Name') '/' num2str(conn.DstPort)], 'autorouting', 'on');
            end
        else
            tag = matlab.lang.makeValidName(conn.SignalName);
            srcKey = sprintf('b%d_p%d', conn.SrcIdx, conn.SrcPort);
            if ~isfield(gotoTags, srcKey)
                srcPos = get_param(conn.SrcBlock, 'Position');
                numPorts = numel(modelsMeta(conn.SrcIdx).OutputNames);
                pY = srcPos(2) + (srcPos(4) - srcPos(2)) * (conn.SrcPort / (numPorts + 1));
                gotoPos = [srcPos(3) + 30, pY - 10, srcPos(3) + 90, pY + 10];
                
                gotoPath = [modelName '/Goto_' tag];
                hGoto = add_block('simulink/Signal Routing/Goto', gotoPath, ...
                    'Position', gotoPos, 'MakeNameUnique', 'on');
                blockHandles = [blockHandles; hGoto]; %#ok<AGROW>
                
                actualGotoName = get_param(hGoto, 'Name');
                set_param(hGoto, 'GotoTag', tag, 'TagVisibility', 'local');
                
                add_line(modelName, [get_param(conn.SrcBlock, 'Name') '/' num2str(conn.SrcPort)], ...
                    [actualGotoName '/1'], 'autorouting', 'on');
                
                gotoTags.(srcKey) = tag;
            end
            
            dstPos = get_param(conn.DstBlock, 'Position');
            numPorts = numel(modelsMeta(conn.DstIdx).InputNames);
            pY = dstPos(2) + (dstPos(4) - dstPos(2)) * (conn.DstPort / (numPorts + 1));
            fromPos = [dstPos(1) - 90, pY - 10, dstPos(1) - 30, pY + 10];
            
            fromPath = [modelName '/From_' tag];
            hFrom = add_block('simulink/Signal Routing/From', fromPath, ...
                'Position', fromPos, 'MakeNameUnique', 'on');
            blockHandles = [blockHandles; hFrom]; %#ok<AGROW>
            
            actualFromName = get_param(hFrom, 'Name');
            set_param(hFrom, 'GotoTag', tag);
            
            if options.AutoDelayFeedback && isFeedback
                delayPos = [fromPos(3) + 5, pY - 10, fromPos(3) + 20, pY + 10];
                delayPath = [modelName '/Delay_' tag];
                hDelay = add_block('simulink/Discrete/Unit Delay', delayPath, ...
                    'Position', delayPos, 'MakeNameUnique', 'on');
                blockHandles = [blockHandles; hDelay]; %#ok<AGROW>
                
                actualDelayName = get_param(hDelay, 'Name');
                
                add_line(modelName, [actualFromName '/1'], [actualDelayName '/1'], 'autorouting', 'on');
                add_line(modelName, [actualDelayName '/1'], ...
                    [get_param(conn.DstBlock, 'Name') '/' num2str(conn.DstPort)], 'autorouting', 'on');
            else
                add_line(modelName, [actualFromName '/1'], ...
                    [get_param(conn.DstBlock, 'Name') '/' num2str(conn.DstPort)], 'autorouting', 'on');
            end
        end
    end
    
    for i = 1:numel(models)
        meta = modelsMeta(i);
        block = refBlockPaths{i};
        blockPos = get_param(block, 'Position');
        
        for pIdx = 1:numel(meta.InputNames)
            inName = meta.InputNames{pIdx};
            isConnected = false;
            for k = 1:numel(connections)
                if strcmp(connections{k}.DstBlock, block) && connections{k}.DstPort == pIdx
                    isConnected = true;
                    break;
                end
            end
            
            if ~isConnected
                pY = blockPos(2) + (blockPos(4) - blockPos(2)) * (pIdx / (numel(meta.InputNames) + 1));
                inPortPos = [blockPos(1) - 150, pY - 7, blockPos(1) - 120, pY + 7];
                inPortPath = [modelName '/' inName];
                
                hIn = add_block('simulink/Sources/In1', inPortPath, ...
                    'Position', inPortPos, 'MakeNameUnique', 'on');
                blockHandles = [blockHandles; hIn]; %#ok<AGROW>
                actualInName = get_param(hIn, 'Name');
                
                add_line(modelName, [actualInName '/1'], [get_param(block, 'Name') '/' num2str(pIdx)], 'autorouting', 'on');
            end
        end
        
        for pIdx = 1:numel(meta.OutputNames)
            outName = meta.OutputNames{pIdx};
            isConnected = false;
            for k = 1:numel(connections)
                if strcmp(connections{k}.SrcBlock, block) && connections{k}.SrcPort == pIdx
                    isConnected = true;
                    break;
                end
            end
            
            if ~isConnected
                pY = blockPos(2) + (blockPos(4) - blockPos(2)) * (pIdx / (numel(meta.OutputNames) + 1));
                outPortPos = [blockPos(3) + 120, pY - 7, blockPos(3) + 150, pY + 7];
                outPortPath = [modelName '/' outName];
                
                hOut = add_block('simulink/Sinks/Out1', outPortPath, ...
                    'Position', outPortPos, 'MakeNameUnique', 'on');
                blockHandles = [blockHandles; hOut]; %#ok<AGROW>
                actualOutName = get_param(hOut, 'Name');
                
                add_line(modelName, [get_param(block, 'Name') '/' num2str(pIdx)], [actualOutName '/1'], 'autorouting', 'on');
            end
        end
    end
    
    if options.WrapInSubsystem && ~isempty(blockHandles)
        validHandles = blockHandles(ishandle(blockHandles));
        if ~isempty(validHandles)
            subsystemHandle = Simulink.BlockDiagram.createSubsystem(validHandles);
            set_param(subsystemHandle, 'Name', 'MainProcess');
        end
    end
    
    for i = 1:numel(modelsMeta)
        if ~modelsMeta(i).WasLoaded && options.CloseReferencedModels
            close_system(modelsMeta(i).Name, 0);
        end
    end
    
    save_system(modelName, targetFile);
    result.OutputFile = targetFile;
end

function [connections, connStats] = listModelConnections(modelName)
    connections = struct('Label', {}, 'System', {}, 'SrcBlockPath', {}, 'SrcPortIndex', {}, 'DstBlockPath', {}, 'DstPortIndex', {}, 'AlreadyDelayed', {});
    connStats = struct();
    
    lines = find_system(modelName, 'FindAll', 'on', 'Type', 'line');
    for i = 1:numel(lines)
        try
            srcBlkH = get_param(lines(i), 'SrcBlockHandle');
            dstBlkH = get_param(lines(i), 'DstBlockHandle');
            srcPortH = get_param(lines(i), 'SrcPortHandle');
            dstPortH = get_param(lines(i), 'DstPortHandle');
            
            if isempty(srcBlkH) || isempty(dstBlkH) || srcBlkH == -1 || any(dstBlkH == -1), continue; end
            
            srcName = get_param(srcBlkH, 'Name');
            srcType = get_param(srcBlkH, 'BlockType');
            srcPortNum = get_param(srcPortH, 'PortNumber');
            
            for j = 1:numel(dstBlkH)
                dBlk = dstBlkH(j);
                dPort = dstPortH(j);
                dstName = get_param(dBlk, 'Name');
                dstType = get_param(dBlk, 'BlockType');
                dstPortNum = get_param(dPort, 'PortNumber');
                
                label = sprintf('From %s [Port %d] -> To %s [Port %d]', srcName, srcPortNum, dstName, dstPortNum);
                isDelayed = strcmp(srcType, 'UnitDelay') || strcmp(dstType, 'UnitDelay');
                
                connections(end+1) = struct(...
                    'Label', label, ...
                    'System', modelName, ...
                    'SrcBlockPath', getfullname(srcBlkH), ...
                    'SrcPortIndex', srcPortNum, ...
                    'DstBlockPath', getfullname(dBlk), ...
                    'DstPortIndex', dstPortNum, ...
                    'AlreadyDelayed', isDelayed); %#ok<AGROW>
            end
        catch
        end
    end
end

function result = insertUnitDelayOnBranch(system, srcBlockPath, srcPortIndex, dstBlockPath, dstPortIndex, options)
    parentSys = fileparts(srcBlockPath);
    if isempty(parentSys), parentSys = system; end
    
    srcPortName = [get_param(srcBlockPath, 'Name') '/' num2str(srcPortIndex)];
    dstPortName = [get_param(dstBlockPath, 'Name') '/' num2str(dstPortIndex)];
    
    try
        delete_line(parentSys, srcPortName, dstPortName);
    catch
    end
    
    delayName = [parentSys '/UnitDelay_Manual'];
    hDelay = add_block('simulink/Discrete/Unit Delay', delayName, 'MakeNameUnique', 'on');
    actualDelayName = get_param(hDelay, 'Name');
    
    srcPos = get_param(srcBlockPath, 'Position');
    dstPos = get_param(dstBlockPath, 'Position');
    midX = round((srcPos(3) + dstPos(1)) / 2);
    midY = round((srcPos(2) + dstPos(4)) / 2);
    set_param(hDelay, 'Position', [midX-15, midY-15, midX+15, midY+15]);
    
    add_line(parentSys, srcPortName, [actualDelayName '/1'], 'autorouting', 'on');
    add_line(parentSys, [actualDelayName '/1'], dstPortName, 'autorouting', 'on');
    
    result = struct('Message', sprintf('Successfully inserted Unit Delay: %s', actualDelayName));
end

function signalReport = configureSubsystemSignals(options)
    subsys = gcb;
    if isempty(subsys)
        error('No block selected in Simulink. Click a Subsystem block first.');
    end
    if ~strcmp(get_param(subsys, 'BlockType'), 'Subsystem')
        error('Selected block is not a Subsystem.');
    end
    
    if options.ProcessInports
        inports = find_system(subsys, 'SearchDepth', 1, 'BlockType', 'Inport');
        for i = 1:numel(inports)
            try
                if options.MustResolve
                    line = get_param(inports(i), 'LineHandles');
                    if line.Outport ~= -1
                        set_param(line.Outport, 'MustResolveToSignalObject', 'on');
                    end
                end
            catch
            end
        end
    end
    
    if options.ProcessOutports
        outports = find_system(subsys, 'SearchDepth', 1, 'BlockType', 'Outport');
        for i = 1:numel(outports)
            try
                line = get_param(outports(i), 'LineHandles');
                if line.Inport ~= -1
                    if options.ShowPropagation
                        set_param(line.Inport, 'ShowPropagatedSignals', 'on');
                    end
                end
            catch
            end
        end
    end
    signalReport = struct('Status', 'Success');
end

function result = extractAttributesCore(subsystemHandle, searchFolder, outputFile, options)
    ports = getSubsystemPorts(subsystemHandle);
    allPorts = {};
    if strcmp(options.PortChoice, 'Inports') || strcmp(options.PortChoice, 'Both')
        allPorts = [allPorts, ports.InportNames];
    end
    if strcmp(options.PortChoice, 'Outports') || strcmp(options.PortChoice, 'Both')
        allPorts = [allPorts, ports.OutportNames];
    end
    
    mFiles = dir(fullfile(searchFolder, '**', '*.m'));
    fidOut = fopen(outputFile, 'w');
    if fidOut == -1
        error('Cannot open output file %s', outputFile);
    end
    
    fprintf(fidOut, '%% Extracted Attribute Records\n');
    fprintf(fidOut, '%% Subsystem: %s\n', ports.Path);
    fprintf(fidOut, '%% Date: %s\n\n', char(datetime('now')));
    
    matchCount = 0;
    for i = 1:numel(mFiles)
        filePath = fullfile(mFiles(i).folder, mFiles(i).name);
        fidIn = fopen(filePath, 'r');
        if fidIn == -1, continue; end
        
        lineNum = 0;
        while ~feof(fidIn)
            line = fgetl(fidIn);
            lineNum = lineNum + 1;
            if ~ischar(line), continue; end
            
            for pIdx = 1:numel(allPorts)
                portTag = allPorts{pIdx};
                if options.CaseInsensitive
                    matched = ~isempty(strfind(lower(line), lower(portTag)));
                else
                    matched = ~isempty(strfind(line, portTag));
                end
                
                if matched
                    fprintf(fidOut, '%% Found in %s (line %d) for tag %s:\n', mFiles(i).name, lineNum, portTag);
                    fprintf(fidOut, '%s\n\n', line);
                    matchCount = matchCount + 1;
                    break;
                end
            end
        end
        fclose(fidIn);
    end
    fclose(fidOut);
    
    result = struct('OutputFile', outputFile, 'MatchCount', matchCount);
end