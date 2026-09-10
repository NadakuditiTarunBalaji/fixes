function teamtools
%TEAMTOOLS Simulink team tools in one simple app.
%
%   teamtools
%
% Opens a single window with two tabs:
%   1. Build Parent Model  - generate a parent model from referenced
%      models (preview first), with a search box that filters the
%      available-models list, and an optional loop breaker that
%      inserts a Unit Delay on a chosen BACKWARD connection
%      (bottom->top / right->left); forward connections are never
%      listed. The loop breaker is the manual fallback for when
%      Auto insert Unit Delays is unchecked.
%   2. Extract Attributes  - collect attribute records from .m files
%      using a selected subsystem's port names as search tags.
%
% All heavy lifting is done by shared engines (buildParentModelCore.m,
% extractAttributesCore.m), which are also used by the command-line
% tools - a fix in one place fixes every front-end.
%
% Requirements: MATLAB R2020a or newer with Simulink.

% ---- make sure the shared engines are reachable --------------------------
appFolder = fileparts(mfilename('fullpath'));
if ~isempty(appFolder)
    addpath(appFolder);
end

% ---- session log: log.txt in the current folder -------------------------
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
    fid = fopen(logPath, 'w');   % truncate even if delete failed
    if fid ~= -1
        fclose(fid);
    end
    diary(logPath);
    fprintf(['=== Simulink Team Tools - session log started %s ', ...
        '(command window, warnings and errors all land in log.txt) ', ...
        '===\n'], char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
catch
    % logging must never keep the app from starting
end

% remember the session's Simulink cache folder (where .slxc files
% land - the current folder by default) so Generate can point it at
% the destination and the app can restore it on close
try
    origCacheFolder = char(get_param(0, 'CacheFolder'));
catch
    origCacheFolder = '';
end

% ---- shared state ---------------------------------------------------------
state = struct( ...
    'AvailableNames',    {{}}, ...   % model names matching the available list
    'AvailableLabels',   {{}}, ...   % list labels without the [added] marker
    'AvailableFilter',   '', ...     % search text applied to the available list
    'Connections',       {{}}, ...   % connection structs for the loop breaker
    'LastGeneratedModel', '', ...
    'ExtractOutput',     '');

% ---- window ---------------------------------------------------------------
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

% Clear All on top: resets every input on all tabs
clearAllTopBtn = uibutton(root, 'push', 'Text', 'Clear All', ...
    'FontSize', 11, 'ButtonPushedFcn', @clearAllData);
safeTooltip(clearAllTopBtn, ['Resets EVERY input on both tabs: model ', ...
    'lists, folders, names, options, and loop breaker fields. The logs are kept.']);
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
    'Text', ['1) Choose the models folder    2) Add models in the order ' ...
    'they should appear    3) Preview    4) Generate'], ...
    'FontAngle', 'italic', 'FontColor', [0.4 0.4 0.4]);
hint1.Layout.Row = 1;
hint1.Layout.Column = [1 6];

lblModelsFolder = uilabel(g1, 'Text', 'Models folder:', 'FontWeight', 'bold');
lblModelsFolder.Layout.Row = 2;
lblModelsFolder.Layout.Column = 1;

modelsFolderEdit = uieditfield(g1, 'text', ...
    'Value', getpref('teamtools', 'ModelsFolder', ''), ...
    'Placeholder', 'Folder that contains the .slx/.mdl models', ...
    'ValueChangedFcn', @onModelsFolderChanged);
modelsFolderEdit.Layout.Row = 2;
modelsFolderEdit.Layout.Column = [2 5];

browseModelsBtn = uibutton(g1, 'push', 'Text', 'Browse...', ...
    'FontSize', 11, ...
    'ButtonPushedFcn', @browseModelsFolder);
browseModelsBtn.Layout.Row = 2;
browseModelsBtn.Layout.Column = 6;

lblAvail = uilabel(g1, 'Text', 'Available models:', 'FontWeight', 'bold');
lblAvail.Layout.Row = 3;
lblAvail.Layout.Column = 1;

% search box: filters the available-models list while you type
filterEdit = uieditfield(g1, 'text', ...
    'Placeholder', 'Type to filter...', ...
    'ValueChangedFcn', @onAvailableFilterChanged);
filterEdit.Layout.Row = 3;
filterEdit.Layout.Column = 2;
safeTooltip(filterEdit, ['Type part of a model or subfolder name and ', ...
    'press Enter to shorten the list; clear the box and press Enter ', ...
    'to show every model again.']);

lblSel = uilabel(g1, 'Text', 'Selected models (order matters):', ...
    'FontWeight', 'bold');
lblSel.Layout.Row = 3;
lblSel.Layout.Column = [4 6];

availableList = uilistbox(g1);
availableList.Layout.Row = 4;
availableList.Layout.Column = [1 2];
safeTooltip(availableList, ...
    'Ctrl+click or Shift+click to select several models at once');

btnGrid = uigridlayout(g1, [6 1]);
btnGrid.Layout.Row = 4;
btnGrid.Layout.Column = 3;
btnGrid.Padding = [2 2 2 2];
btnGrid.RowSpacing = 5;

addBtn = uibutton(btnGrid, 'push', 'Text', 'Add >>', ...
    'FontSize', 11, ...
    'ButtonPushedFcn', @addModel);
addAllBtn = uibutton(btnGrid, 'push', 'Text', 'Add All >>', ...
    'FontSize', 11, ...
    'ButtonPushedFcn', @addAllModels);
safeTooltip(addAllBtn, ['Adds every model shown in the left list - ', ...
    'when a search filter is active, only the matching models ', ...
    'are added.']);
removeBtn = uibutton(btnGrid, 'push', 'Text', 'Remove', ...
    'FontSize', 11, ...
    'ButtonPushedFcn', @removeModel);
clearListBtn = uibutton(btnGrid, 'push', 'Text', 'Clear', ...
    'FontSize', 11, ...
    'ButtonPushedFcn', @clearSelectedModels);
safeTooltip(clearListBtn, ['Empties the selected-models list (the ordered ', ...
    'list on the right) only - folders and options stay as they are.']);
upBtn = uibutton(btnGrid, 'push', 'Text', 'Move Up', ...
    'FontSize', 11, ...
    'ButtonPushedFcn', @moveModelUp);
downBtn = uibutton(btnGrid, 'push', 'Text', 'Move Down', ...
    'FontSize', 11, ...
    'ButtonPushedFcn', @moveModelDown);

selectedList = uilistbox(g1);
selectedList.Layout.Row = 4;
selectedList.Layout.Column = [4 6];
safeTooltip(selectedList, ...
    'Ctrl+click or Shift+click to select several models at once');

% multi-selection where the release supports it (graceful fallback to
% single selection on R2020a, which has no multi-select list box)
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
    'Placeholder', '(same as the models folder)');
saveFolderEdit.Layout.Row = 5;
saveFolderEdit.Layout.Column = 5;

browseSaveBtn = uibutton(g1, 'push', 'Text', 'Browse...', ...
    'FontSize', 11, ...
    'ButtonPushedFcn', @browseSaveFolder);
browseSaveBtn.Layout.Row = 5;
browseSaveBtn.Layout.Column = 6;

chkCase = uicheckbox(g1, ...
    'Text', 'Match port names case-insensitively', 'Value', true);
chkCase.Layout.Row = 6;
chkCase.Layout.Column = [1 3];

chkBackup = uicheckbox(g1, ...
    'Text', 'Backup existing model (.bak)', 'Value', true);
chkBackup.Layout.Row = 6;
chkBackup.Layout.Column = [4 6];

chkClose = uicheckbox(g1, ...
    'Text', 'Close referenced models when done', 'Value', true);
chkClose.Layout.Row = 7;
chkClose.Layout.Column = [1 3];

chkWrap = uicheckbox(g1, ...
    'Text', 'Create main subsystem (wrap all contents)', 'Value', true);
safeTooltip(chkWrap, ['After generation, every block and connection is ', ...
    'placed inside one main subsystem of the parent model.']);
chkWrap.Layout.Row = 7;
chkWrap.Layout.Column = [4 6];

lblConnMethod = uilabel(g1, 'Text', 'Connect via:');
lblConnMethod.Layout.Row = 8;
lblConnMethod.Layout.Column = 1;

connMethodDrop = uidropdown(g1, ...
    'Items', {'From/Goto blocks', 'Direct lines'}, ...
    'Value', 'From/Goto blocks');
safeTooltip(connMethodDrop, ['From/Goto blocks: signals travel through ', ...
    'Goto/From tags - no crossing lines. Direct lines: physical lines ', ...
    'from each output to every matching input.']);
connMethodDrop.Layout.Row = 8;
connMethodDrop.Layout.Column = [2 3];

lblArrange = uilabel(g1, 'Text', 'Arrangement:');
lblArrange.Layout.Row = 8;
lblArrange.Layout.Column = 4;

layoutDrop = uidropdown(g1, ...
    'Items', {'Horizontal (side by side)', 'Vertical (stacked)'}, ...
    'Value', 'Horizontal (side by side)');
layoutDrop.Layout.Row = 8;
layoutDrop.Layout.Column = [5 6];

chkColor = uicheckbox(g1, 'Text', 'Color blocks by model', 'Value', true);
chkColor.Layout.Row = 9;
chkColor.Layout.Column = [1 3];

chkAutoDelay = uicheckbox(g1, ...
    'Text', 'Auto Unit Delay on feedback signals', 'Value', true);
safeTooltip(chkAutoDelay, ['Feedback signals (a bottom model feeding a ', ...
    'model above it in the list, or a model feeding its own input) get ', ...
    'a Unit Delay at that model''s INPUT - between the From block and ', ...
    'the input port - which prevents algebraic loops.']);
chkAutoDelay.Layout.Row = 9;
chkAutoDelay.Layout.Column = [4 6];

% Single master Block Spacing configuration row
lblSpacing = uilabel(g1, 'Text', 'Block spacing:');
lblSpacing.Layout.Row = 10;
lblSpacing.Layout.Column = 1;

spacingEdit = uieditfield(g1, 'numeric', ...
    'Value', 100, 'Limits', [55 1000], ...
    'RoundFractionalValues', 'on');
safeTooltip(spacingEdit, ['Standard layout spacing base in points (Minimum 55). ', ...
    'All tag and sub-block gaps automatically scale proportionally to keep your diagram aligned.']);
spacingEdit.Layout.Row = 10;
spacingEdit.Layout.Column = 2;

lblSpacingHint = uilabel(g1, ...
    'Text', 'points base scale (all block gaps scale proportionally to prevent overlaps)', ...
    'FontAngle', 'italic', 'FontColor', [0.4 0.4 0.4]);
lblSpacingHint.Layout.Row = 10;
lblSpacingHint.Layout.Column = [3 6];

previewBtn = uibutton(g1, 'push', 'Text', 'Preview', ...
    'FontSize', 12, ...
    'ButtonPushedFcn', @doPreview);
previewBtn.Layout.Row = 11;
previewBtn.Layout.Column = [2 3];

generateBtn = uibutton(g1, 'push', 'Text', 'Generate', ...
    'FontSize', 12, ...
    'FontWeight', 'bold', 'ButtonPushedFcn', @doGenerate);
generateBtn.Layout.Row = 11;
generateBtn.Layout.Column = [4 5];

lblLoop = uilabel(g1, 'Text', ...
    ['Loop breaker - use when Simulink reports an algebraic loop:  ' ...
    '1) model name  2) Refresh list  3) pick the looping connection  ' ...
    '4) Insert Unit Delay'], ...
    'FontWeight', 'bold');
lblLoop.Layout.Row = 12;
lblLoop.Layout.Column = [1 6];

connModelEdit = uieditfield(g1, 'text', ...
    'Placeholder', 'model name (filled after Generate)');
connModelEdit.Layout.Row = 13;
connModelEdit.Layout.Column = [1 2];

refreshConnBtn = uibutton(g1, 'push', 'Text', 'Refresh list', ...
    'FontSize', 11, ...
    'ButtonPushedFcn', @refreshConnections);
refreshConnBtn.Layout.Row = 13;
refreshConnBtn.Layout.Column = 3;

connDropDown = uidropdown(g1, 'Items', {'(no connections yet)'});
connDropDown.Layout.Row = 13;
connDropDown.Layout.Column = [4 5];

insertDelayBtn = uibutton(g1, 'push', 'Text', 'Insert Unit Delay', ...
    'FontSize', 11, ...
    'Enable', 'off', 'ButtonPushedFcn', @insertDelay);
insertDelayBtn.Layout.Row = 13;
insertDelayBtn.Layout.Column = 6;

% filter for the connection list: show only connections with a delay
chkDelayFilter = uicheckbox(g1, ...
    'Text', 'Show only connections that already have a Unit Delay', ...
    'ValueChangedFcn', @refreshConnections);
safeTooltip(chkDelayFilter, ['Shows only the connections that already contain ', ...
    'a Unit Delay - handy for checking which feedback signals were ', ...
    'delayed automatically.']);
chkDelayFilter.Layout.Row = 14;
chkDelayFilter.Layout.Column = [1 6];

% second filter: escape hatch to see every connection at once
chkShowAll = uicheckbox(g1, ...
    'Text', 'Show all connections (with and without Unit Delay)', ...
    'ValueChangedFcn', @refreshConnections);
safeTooltip(chkShowAll, ['Shows every listed connection, with or without a ', ...
    'Unit Delay. Default (both unticked): only the connections that ', ...
    'still NEED a Unit Delay.']);
chkShowAll.Layout.Row = 15;
chkShowAll.Layout.Column = [1 6];

lblSignals = uilabel(g1, 'Text', 'Subsystem signals:', ...
    'FontWeight', 'bold');
lblSignals.Layout.Row = 16;
lblSignals.Layout.Column = [1 2];

configureSignalsBtn = uibutton(g1, 'push', ...
    'Text', 'Configure Signals', ...
    'FontSize', 11, ...
    'ButtonPushedFcn', @doConfigureSignals);
safeTooltip(configureSignalsBtn, ['Works on the Subsystem block that is ', ...
    'currently SELECTED in the open model. For every Inport/Outport ', ...
    'name inside it: creates a Simulink.Signal object (in the data ', ...
    'dictionary when one is attached, otherwise the model workspace), ', ...
    'names the connecting lines, enables MustResolveToSignalObject, ', ...
    'and shows propagated signal names.']);
configureSignalsBtn.Layout.Row = 16;
configureSignalsBtn.Layout.Column = [3 4];

lblSignalsHint = uilabel(g1, ...
    'Text', 'select a Subsystem in the model, then press', ...
    'FontAngle', 'italic', 'FontColor', [0.4 0.4 0.4]);
lblSignalsHint.Layout.Row = 16;
lblSignalsHint.Layout.Column = [5 6];

% Configure Signals: which parts to process
chkCfgInports = uicheckbox(g1, 'Text', 'Inports', 'Value', true);
safeTooltip(chkCfgInports, ['Process the Subsystem''s Inport signals: ', ...
    'create/validate Simulink.Signal objects and name the lines.']);
chkCfgInports.Layout.Row = 17;
chkCfgInports.Layout.Column = [1 2];

chkCfgOutports = uicheckbox(g1, 'Text', 'Outports', 'Value', true);
safeTooltip(chkCfgOutports, ['Process the Subsystem''s Outport signals: ', ...
    'create/validate Simulink.Signal objects and name the lines.']);
chkCfgOutports.Layout.Row = 17;
chkCfgOutports.Layout.Column = [3 4];

chkCfgPropagation = uicheckbox(g1, 'Text', 'Propagation', 'Value', true);
safeTooltip(chkCfgPropagation, 'Display the propagated signal names on the lines.');
chkCfgPropagation.Layout.Row = 17;
chkCfgPropagation.Layout.Column = 5;

chkCfgResolver = uicheckbox(g1, 'Text', 'Resolver', 'Value', true);
safeTooltip(chkCfgResolver, ['Enable "Signal name must resolve to signal ', ...
    'object" (MustResolveToSignalObject) on the named lines.']);
chkCfgResolver.Layout.Row = 17;
chkCfgResolver.Layout.Column = 6;

log1 = uitextarea(g1, 'Editable', 'off', ...
    'Value', {'Ready. Choose a models folder to begin.'});
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

hint2 = uilabel(g2, ...
    'Text', ['1) Click a subsystem in your Simulink model    2) Refresh    ' ...
    '3) Choose folders    4) Extract'], ...
    'FontAngle', 'italic', 'FontColor', [0.4 0.4 0.4]);
hint2.Layout.Row = 1;
hint2.Layout.Column = [1 6];

lblSub = uilabel(g2, 'Text', 'Selected subsystem:', 'FontWeight', 'bold');
lblSub.Layout.Row = 2;
lblSub.Layout.Column = 1;

subsystemLabel = uilabel(g2, 'Text', '<no subsystem selected>', ...
    'FontColor', [0.75 0 0]);
subsystemLabel.Layout.Row = 2;
subsystemLabel.Layout.Column = [2 5];

refreshSubBtn = uibutton(g2, 'push', 'Text', 'Refresh', ...
    'FontSize', 11, ...
    'ButtonPushedFcn', @refreshSubsystem);
refreshSubBtn.Layout.Row = 2;
refreshSubBtn.Layout.Column = 6;

lblPorts = uilabel(g2, 'Text', 'Ports to use as tags:', 'FontWeight', 'bold');
lblPorts.Layout.Row = 3;
lblPorts.Layout.Column = 1;

portDropDown = uidropdown(g2, ...
    'Items', {'Inports', 'Outports', 'Both'}, 'Value', 'Both');
portDropDown.Layout.Row = 3;
portDropDown.Layout.Column = [2 3];

lblInfo = uilabel(g2, 'Text', 'File information:', 'FontWeight', 'bold');
lblInfo.Layout.Row = 3;
lblInfo.Layout.Column = 4;

infoDropDown = uidropdown(g2, ...
    'Items', {'Header + source comments', 'Header only', 'Source comments only'}, ...
    'Value', 'Header + source comments');
infoDropDown.Layout.Row = 3;
infoDropDown.Layout.Column = [5 6];

lblSearch = uilabel(g2, 'Text', 'Search folder:', 'FontWeight', 'bold');
lblSearch.Layout.Row = 4;
lblSearch.Layout.Column = 1;

searchEdit = uieditfield(g2, 'text', ...
    'Value', getpref('teamtools', 'SearchFolder', ''), ...
    'Placeholder', 'Parent folder containing the .m files to scan');
searchEdit.Layout.Row = 4;
searchEdit.Layout.Column = [2 5];

browseSearchBtn = uibutton(g2, 'push', 'Text', 'Browse...', ...
    'FontSize', 11, ...
    'ButtonPushedFcn', @browseSearchFolder);
browseSearchBtn.Layout.Row = 4;
browseSearchBtn.Layout.Column = 6;

lblDest = uilabel(g2, 'Text', 'Destination file:', 'FontWeight', 'bold');
lblDest.Layout.Row = 5;
lblDest.Layout.Column = 1;

destEdit = uieditfield(g2, 'text', ...
    'Value', getpref('teamtools', 'OutputFile', ''), ...
    'Placeholder', 'ExtractedAttributes.m');
destEdit.Layout.Row = 5;
destEdit.Layout.Column = [2 5];

browseDestBtn = uibutton(g2, 'push', 'Text', 'Browse...', ...
    'FontSize', 11, ...
    'ButtonPushedFcn', @browseOutputFile);
browseDestBtn.Layout.Row = 5;
browseDestBtn.Layout.Column = 6;

chkCase2 = uicheckbox(g2, 'Text', 'Case-insensitive matching', 'Value', true);
chkCase2.Layout.Row = 6;
chkCase2.Layout.Column = [1 3];

extractBtn = uibutton(g2, 'push', 'Text', 'Extract', ...
    'FontSize', 11, ...
    'FontWeight', 'bold', 'ButtonPushedFcn', @doExtract);
extractBtn.Layout.Row = 6;
extractBtn.Layout.Column = 4;

openOutputBtn = uibutton(g2, 'push', 'Text', 'Open Output', ...
    'FontSize', 11, ...
    'Enable', 'off', 'ButtonPushedFcn', @openOutputFile);
openOutputBtn.Layout.Row = 6;
openOutputBtn.Layout.Column = 5;

openFolderBtn = uibutton(g2, 'push', 'Text', 'Open Folder', ...
    'FontSize', 11, ...
    'Enable', 'off', 'ButtonPushedFcn', @openOutputFolder);
openFolderBtn.Layout.Row = 6;
openFolderBtn.Layout.Column = 6;

lblConvert = uilabel(g2, 'Text', 'convert_m_to_sldd:', ...
    'FontWeight', 'bold');
lblConvert.Layout.Row = 7;
lblConvert.Layout.Column = 1;

convertPathEdit = uieditfield(g2, 'text', ...
    'Value', getpref('teamtools', 'ConvertPath', ''), ...
    'Placeholder', 'Path of convert_m_to_sldd.m or its folder');
convertPathEdit.Layout.Row = 7;
convertPathEdit.Layout.Column = [2 3];

browseConvertBtn = uibutton(g2, 'push', 'Text', 'Browse...', ...
    'FontSize', 11, 'ButtonPushedFcn', @browseConvertPath);
browseConvertBtn.Layout.Row = 7;
browseConvertBtn.Layout.Column = 4;

convertBtn = uibutton(g2, 'push', 'Text', 'Convert to .sldd', ...
    'FontSize', 11, 'FontWeight', 'bold', ...
    'ButtonPushedFcn', @doConvertToSldd);
safeTooltip(convertBtn, ['Runs the team''s convert_m_to_sldd function ', ...
    'on the extracted attributes file (.m). Set the path to the ', ...
    'convert_m_to_sldd.m file - or the folder that contains it - ', ...
    'first; use Browse... to pick it.']);
convertBtn.Layout.Row = 7;
convertBtn.Layout.Column = [5 6];

lblSlddDest = uilabel(g2, 'Text', 'Save .sldd in:', ...
    'FontWeight', 'bold');
lblSlddDest.Layout.Row = 8;
lblSlddDest.Layout.Column = 1;

slddDestEdit = uieditfield(g2, 'text', ...
    'Value', getpref('teamtools', 'SlddDestFolder', ''), ...
    'Placeholder', 'Folder for the created .sldd (empty = .m folder)');
slddDestEdit.Layout.Row = 8;
slddDestEdit.Layout.Column = [2 3];
safeTooltip(slddDestEdit, ['Where the .sldd file(s) created by the ', ...
    'conversion are moved. Empty = the folder of the converted .m ', ...
    'file. Nothing is left behind in the MATLAB current folder.']);

browseSlddDestBtn = uibutton(g2, 'push', 'Text', 'Browse...', ...
    'FontSize', 11, 'ButtonPushedFcn', @browseSlddDest);
browseSlddDestBtn.Layout.Row = 8;
browseSlddDestBtn.Layout.Column = 4;

lblTags = uilabel(g2, 'Text', 'Tags that will be searched:', ...
    'FontWeight', 'bold');
lblTags.Layout.Row = 9;
lblTags.Layout.Column = [1 6];

tagsList = uilistbox(g2);
tagsList.Layout.Row = 10;
tagsList.Layout.Column = [1 6];

log2 = uitextarea(g2, 'Editable', 'off', ...
    'Value', {'Ready. Select a subsystem in Simulink and press Refresh.'});
log2.Layout.Row = 11;
log2.Layout.Column = [1 6];

% ---- initial content -------------------------------------------------------
if isfolder(char(strtrim(modelsFolderEdit.Value)))
    refreshModelList();
else
    modelsFolderEdit.Value = '';
end

% =========================================================================
%  NESTED CALLBACKS - TAB 1
% =========================================================================
function setStatus(message)
statusLabel.Text = char(message);
drawnow limitrate;
end

function bringAppToFront()
%BRINGAPPTOFRONT Raise the app window after a native file dialog.
try
    drawnow;
    figure(app);
catch
    try
        app.Visible = 'on';
    catch
    end
end
end

function onAppClose(~, ~)
%ONAPPCLOSE Stop the log.txt diary, then close the window.

try
    fprintf(['=== Simulink Team Tools - session log closed %s ', ...
        '===\n'], char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));
catch
end
try
    diary('off');
    if prevDiaryOn
        diary(prevDiaryFile);   % the user ran their own diary
    end
catch
end
try
    set_param(0, 'CacheFolder', origCacheFolder);
catch
end
delete(app);
end

function browseModelsFolder(~, ~)
startFolder = pwd;
candidate = char(strtrim(modelsFolderEdit.Value));
if isfolder(candidate)
    startFolder = candidate;
end
chosenFolder = uigetdir(startFolder, 'Select the folder containing the models');
bringAppToFront();
if isequal(chosenFolder, 0)
    return;
end
modelsFolderEdit.Value = chosenFolder;
setpref('teamtools', 'ModelsFolder', chosenFolder);
if isempty(strtrim(saveFolderEdit.Value))
    saveFolderEdit.Value = chosenFolder;
end
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
if ~isfolder(folder)
    return;
end
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

duplicateNames = unique(names);
if numel(duplicateNames) < numel(names)
    logTo(log1, ['Warning: some model filenames appear more than once ', ...
        'in different subfolders. Keep filenames unique - duplicates ', ...
        'cannot be selected.']);
end
if isempty(strtrim(state.AvailableFilter))
    setStatus(sprintf('%d model(s) found.', numel(files)));
else
    foundShown = numel(availableList.Items);
    if foundShown == 1 && ...
            strcmp(availableList.Items{1}, '(no matching models)')
        foundShown = 0;
    end
    setStatus(sprintf(['%d model(s) found, %d match the search ', ...
        'filter.'], numel(files), foundShown));
end
end

function updateAvailableLabels()
%UPDATEAVAILABLELABELS Refresh the left list: apply the search filter
% and mark models that are already in the selected list.

baseLabels = state.AvailableLabels;
if isempty(baseLabels)
    return;
end

% search filter: keep the models whose label (name + subfolder)
% contains the typed text, case-insensitively
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

if isequal(availableList.Items, marked)
    return;   % nothing changed - avoid unnecessary updates
end

wasChar = ischar(availableList.Value);
currentSelection = asCell(availableList.Value);
% strip the marker before matching against the base labels
currentBase = strrep(currentSelection, '  [added]', '');
selectedPositions = find(ismember(baseLabels, currentBase));

availableList.Items = marked;
if isempty(selectedPositions)
    try
        availableList.Value = marked{1};
    catch
    end
else
    setListSelection(availableList, marked(selectedPositions), wasChar);
end
end

function onAvailableFilterChanged(src, ~)
%ONAVAILABLEFILTERCHANGED Filter the available list (Enter/focus loss).

state.AvailableFilter = char(strtrim(src.Value));
if isempty(state.AvailableNames)
    return;
end
updateAvailableLabels();

filterTotal = numel(state.AvailableNames);
filterShown = numel(availableList.Items);
if filterShown == 1 && ...
        strcmp(availableList.Items{1}, '(no matching models)')
    setStatus(sprintf('No models match "%s".', state.AvailableFilter));
elseif isempty(strtrim(state.AvailableFilter))
    setStatus(sprintf('Showing all %d model(s).', filterTotal));
else
    setStatus(sprintf('Search: %d of %d model(s) shown.', ...
        filterShown, filterTotal));
end
end

function addModel(~, ~)
selectedLabels = asCell(availableList.Value);
if isempty(selectedLabels)
    setStatus('Select one or more models in the left list first.');
    return;
end
addModelsByLabel(selectedLabels);
end

function addAllModels(~, ~)
%ADDALLMODELS Add every model shown in the available list. When a
% search filter is active, only the matching models are added.
addModelsByLabel(availableList.Items);
end

function addModelsByLabel(labelsToAdd)
%ADDMODELSBYLABEL Add the models behind these labels, in listed order.

if isempty(state.AvailableNames)
    setStatus('No models available - choose a models folder first.');
    return;
end

% match labels against the FULL available list (not the visible list
% box), so adding keeps working while a search filter is active
newNames = {};
skippedCount = 0;
for availIndex = 1:numel(state.AvailableLabels)
    baseLabel = state.AvailableLabels{availIndex};
    candidateName = state.AvailableNames{availIndex};
    alreadyAdded = any(strcmpi(selectedList.Items, candidateName));
    itemLabel = baseLabel;
    if alreadyAdded
        itemLabel = [baseLabel '  [added]'];
    end
    if ~any(strcmp(labelsToAdd, itemLabel))
        continue;
    end
    if alreadyAdded
        skippedCount = skippedCount + 1;
    else
        newNames{end + 1} = candidateName; %#ok<AGROW>
    end
end

if isempty(newNames) && skippedCount == 0
    setStatus('No matching model(s) to add.');
    return;
end
if isempty(newNames)
    setStatus('Those model(s) are already in the selected list.');
    return;
end

wasChar = ischar(selectedList.Value);
selectedList.Items = [selectedList.Items, newNames];
setListSelection(selectedList, newNames, wasChar);
updateAvailableLabels();

message = sprintf('Added %d model(s).', numel(newNames));
if skippedCount > 0
    message = sprintf('%s  (%d already added - skipped)', message, ...
        skippedCount);
end
setStatus(message);
end

function removeModel(~, ~)
if isempty(selectedList.Items)
    setStatus('The selected list is already empty.');
    return;
end
selectedValues = asCell(selectedList.Value);
if isempty(selectedValues)
    setStatus('Select one or more models in the right list first.');
    return;
end
items = selectedList.Items;
keepMask = ~ismember(items, selectedValues);
removedCount = numel(items) - sum(keepMask);
items = items(keepMask);
selectedList.Items = items;
if ~isempty(items)
    selectedList.Value = items{1};
end
updateAvailableLabels();
setStatus(sprintf('Removed %d model(s).', removedCount));
end

function clearSelectedModels(~, ~)
%CLEARSELECTEDMODELS Empty the selected-models list only (Clear button).

if isempty(selectedList.Items)
    setStatus('The selected list is already empty.');
    return;
end
removedCount = numel(selectedList.Items);
selectedList.Items = {};
updateAvailableLabels();
setStatus(sprintf('Cleared %d model(s) from the selected list.', ...
    removedCount));
end

function clearAllData(~, ~)
%CLEARALLDATA Reset every input on all tabs in one click (Clear All).

% --- Tab 1: model selection and generation options
filterEdit.Value = '';
state.AvailableFilter = '';
% FIX 1: Explicitly reset background state data to avoid search reappearances
state.AvailableNames = {};
state.AvailableLabels = {};
selectedList.Items = {};
updateAvailableLabels();
modelsFolderEdit.Value = '';
availableList.Items = {};
try
    availableList.Value = '';
catch
end
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

% --- Tab 1: loop breaker
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
chkCfgInports.Value = true;
chkCfgOutports.Value = true;
chkCfgPropagation.Value = true;
chkCfgResolver.Value = true;

% --- Tab 2: extract attributes
subsystemLabel.Text = '<no subsystem selected>';
subsystemLabel.FontColor = [0.75 0 0];
portDropDown.Value = 'Both';
infoDropDown.Value = 'Header + source comments';
searchEdit.Value = '';
destEdit.Value = '';
convertPathEdit.Value = '';
slddDestEdit.Value = '';
chkCase2.Value = true;
tagsList.Items = {};
try
    tagsList.Value = '';
catch
end
state.ExtractOutput = '';
openOutputBtn.Enable = 'off';
openFolderBtn.Enable = 'off';

logTo(log1, 'All inputs cleared (all tabs). The log is kept.');
setStatus('All inputs cleared.');
end

function moveModelUp(~, ~)
moveModel(-1);
end

function moveModelDown(~, ~)
moveModel(1);
end

function moveModel(direction)
%MOVEMODEL Move every selected model one position up (-1) or down (+1).
% Works for a single selection and for multiple selections.

if isempty(selectedList.Items)
    setStatus('The selected list is empty.');
    return;
end
selectedValues = asCell(selectedList.Value);
if isempty(selectedValues)
    setStatus('Select one or more models in the right list first.');
    return;
end

items = selectedList.Items;
selectedMask = ismember(items, selectedValues);
wasChar = ischar(selectedList.Value);

if direction < 0
    scanOrder = 1:numel(items);        % moving up: work top to bottom
else
    scanOrder = numel(items):-1:1;     % moving down: work bottom to top
end

for k = scanOrder
    if ~selectedMask(k)
        continue;
    end
    targetIndex = k + direction;
    if targetIndex < 1 || targetIndex > numel(items)
        continue;
    end
    if selectedMask(targetIndex)
        continue;   % part of the same block - already handled by a neighbour
    end
    tmp = items{k};
    items{k} = items{targetIndex};
    items{targetIndex} = tmp;
    tmpMask = selectedMask(k);
    selectedMask(k) = selectedMask(targetIndex);
    selectedMask(targetIndex) = tmpMask;
end

selectedList.Items = items;
setListSelection(selectedList, selectedValues, wasChar);
end

function browseSaveFolder(~, ~)
startFolder = pwd;
candidate = char(strtrim(modelsFolderEdit.Value));
if isfolder(candidate)
    startFolder = candidate;
end
candidate = char(strtrim(saveFolderEdit.Value));
if isfolder(candidate)
    startFolder = candidate;
end
chosenFolder = uigetdir(startFolder, 'Select where to save the generated model');
bringAppToFront();
if isequal(chosenFolder, 0)
    return;
end
saveFolderEdit.Value = chosenFolder;
setpref('teamtools', 'SaveFolder', chosenFolder);
end

function s = integrationStyle()
%INTEGRATIONSTYLE Read the integration-style controls into option fields.

s = struct();
if strcmp(connMethodDrop.Value, 'Direct lines')
    s.ConnectionMethod = 'lines';
else
    s.ConnectionMethod = 'fromgoto';
end
if startsWith(layoutDrop.Value, 'Horizontal')
    s.Layout = 'horizontal';
else
    s.Layout = 'vertical';
end
s.ColorBlocks = logical(chkColor.Value);
s.AutoDelayFeedback = logical(chkAutoDelay.Value);
s.BlockSpacing = spacingPoints();

% Call the automatic proportional spacing logic
spacingGapValues = spacingGaps();
s.FromModelGap = spacingGapValues.FromModelGap;
s.ModelGotoGap = spacingGapValues.ModelGotoGap;
s.FromToDelayGap = spacingGapValues.FromToDelayGap;
s.ModelToModelGap = spacingGapValues.ModelToModelGap;
end

function spacing = spacingPoints()
%SPACINGPOINTS Validated block spacing from the field (min 55 points).
try
    value = double(spacingEdit.Value);
catch
    value = 100;
end
if isnan(value) || value < 55
    value = 55;
end
spacing = round(value);
end

function gaps = spacingGaps()
%SPACINGGAPS Auto-calculates all layout gaps proportionally from the user's master spacing base.
    baseVal = spacingPoints();
    gaps = struct( ...
        'FromModelGap',   baseVal, ...                % 100% of base (default 100)
        'ModelGotoGap',   baseVal, ...                % 100% of base (default 100)
        'FromToDelayGap', round(baseVal * 0.40), ...  % 40% of base (default 40)
        'ModelToModelGap', round(baseVal * 4.00));    % 400% of base (default 400)
end

function [folder, models, modelName, saveFolder] = validateTab1()
folder = char(strtrim(modelsFolderEdit.Value));
if ~isfolder(folder)
    notify(app, 'Choose a valid models folder first (Browse...).', ...
        'Missing folder', 'warning');
    folder = '';
    return;
end
models = selectedList.Items;
if isempty(models)
    notify(app, 'Add at least one model to the selected list.', ...
        'No models selected', 'warning');
    models = {};
    return;
end
modelName = char(strtrim(nameEdit.Value));
if isempty(modelName)
    modelName = 'GeneratedReferenceModel';
    nameEdit.Value = modelName;
    logTo(log1, sprintf('No name entered - using "%s".', modelName));
end
validName = matlab.lang.makeValidName(modelName, ...
    'ReplacementStyle', 'underscore');
if ~strcmp(validName, modelName)
    logTo(log1, sprintf('Name adjusted to a valid MATLAB name: "%s".', validName));
    modelName = validName;
end
saveFolder = char(strtrim(saveFolderEdit.Value));
if isempty(saveFolder)
    saveFolder = folder;
    saveFolderEdit.Value = folder;
end
% FIX 4: Implemented immediate return on validation check for safety.
if ~isfolder(saveFolder)
    notify(app, 'The "Save in folder" path does not exist.', ...
        'Invalid folder', 'warning');
    folder = '';
    return;
end
end

function doPreview(~, ~)
[folder, models, modelName, saveFolder] = validateTab1();
if isempty(folder) || isempty(models)
    return;
end

logTo(log1, sprintf('Preview: %d model(s) -> "%s".', numel(models), modelName));

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
    'FromModelGap',         styleOpts.FromModelGap, ...
    'ModelGotoGap',         styleOpts.ModelGotoGap, ...
    'FromToDelayGap',       styleOpts.FromToDelayGap, ...
    'ModelToModelGap',      styleOpts.ModelToModelGap, ...
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
setStatus('Preview complete - review it above, then press Generate.');
notify(app, sprintf(['Preview complete.\n\n%d model(s), %d internal ', ...
    'connection(s), %d root input(s), %d root output(s).\n', ...
    'Check the log for warnings before generating.'], ...
    numel(result.Models), result.Counts.Internal, ...
    result.Counts.RootInputs, result.Counts.RootOutputs), ...
    'Preview complete', 'info');
end

function doGenerate(~, ~)
[folder, models, modelName, saveFolder] = validateTab1();
if isempty(folder) || isempty(models)
    return;
end

logTo(log1, sprintf('Generate: building "%s" from %d model(s).', ...
    modelName, numel(models)));

targetFile = fullfile(saveFolder, [modelName '.slx']);
overwrite = false;
if isfile(targetFile)
    doOverwrite = confirmDialog(app, ...
        sprintf(['This model file already exists:\n%s\n\n', ...
        'Overwrite it? (a .bak backup is kept by default)'], targetFile), ...
        'Overwrite model?', 'Yes, overwrite', 'Cancel');
    if ~doOverwrite
        setStatus('Generation cancelled.');
        return;
    end
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
    'FromModelGap',         styleOpts.FromModelGap, ...
    'ModelGotoGap',         styleOpts.ModelGotoGap, ...
    'FromToDelayGap',       styleOpts.FromToDelayGap, ...
    'ModelToModelGap',      styleOpts.ModelToModelGap, ...
    'ConfigParameters',     {{'UseDivisionForNetSlopeComputation'}});

% point the session's Simulink cache folder at the destination, so
% the .slxc cache files of the generated model AND the referenced
% models land there instead of the folder MATLAB was started in;
% the previous setting is restored when the app closes
try
    if cacheFolderWritable(saveFolder)
        set_param(0, 'CacheFolder', absFolder(saveFolder));
        logTo(log1, sprintf(['Simulink cache folder (.slxc files) ', ...
            'pointed at the destination:\n  %s'], ...
            absFolder(saveFolder)));
    else
        logTo(log1, ['Destination folder is not writable - .slxc ', ...
            'cache files stay in the MATLAB current folder.']);
    end
catch
end

setStatus('Generating...');
generateBtn.Enable = 'off';
previewBtn.Enable = 'off';
p = makeProgress(app, 'Generating parent model');
try
    options.ProgressFcn = @(fraction, message) p.set(fraction, message);
    options.CancelRequestedFcn = @() p.cancelled();
    result = buildParentModelCore(folder, models, modelName, options);
    p.close();
catch generateError
    p.close();
    generateBtn.Enable = 'on';
    previewBtn.Enable = 'on';
    setStatus('Generation failed.');
    logTo(log1, ['ERROR: ' errorDetails(generateError)]);
    notify(app, errorDetails(generateError), 'Generation failed', 'error');
    return;
end
generateBtn.Enable = 'on';
previewBtn.Enable = 'on';

if result.Cancelled
    setStatus('Generation cancelled.');
    logTo(log1, 'Generation cancelled by user - nothing was saved.');
    return;
end

lines = {};
lines{end + 1} = '===============================================';
lines{end + 1} = 'Generation completed successfully';
lines{end + 1} = sprintf('Generated model : %s', result.OutputFile);
lines{end + 1} = sprintf('Referenced models : %d', numel(result.Models));
if styleOpts.ColorBlocks
    colorState = 'on';
else
    colorState = 'off';
end
if styleOpts.AutoDelayFeedback
    delayState = 'on';
else
    delayState = 'off';
end
lines{end + 1} = sprintf('Style : %s | %s | colors: %s | auto delay: %s', ...
    styleOpts.ConnectionMethod, styleOpts.Layout, colorState, delayState);
lines{end + 1} = sprintf('Internal connections : %d', result.Counts.Internal);
lines{end + 1} = sprintf('Root inputs : %d | Root outputs : %d', ...
    result.Counts.RootInputs, result.Counts.RootOutputs);
if ~isempty(result.BackupFile)
    lines{end + 1} = sprintf('Backup of previous model : %s', result.BackupFile);
end
if ~isempty(result.SubsystemName)
    lines{end + 1} = sprintf('Contents wrapped in subsystem : %s', ...
        result.SubsystemName);
end
if ~isempty(result.Notes)
    lines{end + 1} = 'Notes:';
    for noteIndex = 1:numel(result.Notes)
        lines{end + 1} = ['  - ' result.Notes{noteIndex}];
    end
end
if isempty(result.Warnings)
    lines{end + 1} = 'No warnings.';
else
    lines{end + 1} = 'Warnings:';
    for warningIndex = 1:numel(result.Warnings)
        lines{end + 1} = ['  - ' result.Warnings{warningIndex}];
    end
end
lines{end + 1} = '===============================================';
logMany(log1, lines);

state.LastGeneratedModel = result.TargetModel;
setpref('teamtools', 'GeneratedModel', result.TargetModel);
connModelEdit.Value = result.TargetModel;
% FIX 2: Added the essential .m extension to allow downstream path validation on extraction
destEdit.Value = [result.TargetModel, '_data.m'];
logTo(log1, sprintf(['Extract destination (Tab 2) set to "%s_data.m" - ', ...
    'edit it there if you want a different name.'], ...
    result.TargetModel));
refreshConnections();

if isempty(result.Warnings)
    setStatus('Model generated successfully.');
    noteText = '';
    if ~isempty(result.Notes)
        noteText = sprintf('\n\n%d note(s) in the log (informational).', ...
            numel(result.Notes));
    end
    notify(app, sprintf(['Model generated successfully:\n\n%s\n\n', ...
        '%d internal connection(s), %d root input(s), %d root output(s).%s'], ...
        result.OutputFile, result.Counts.Internal, ...
        result.Counts.RootInputs, result.Counts.RootOutputs, noteText), ...
        'Generation complete', 'success');
else
    setStatus('Model generated with warnings - see the log above.');
    if ~isempty(regexpi(strjoin(result.Warnings, char(10)), ...
            'could not update the diagram'))
        extraText = ['Simulink could not update the diagram (see the ', ...
            'log). Break a remaining algebraic loop in the Loop ', ...
            'breaker tab: Refresh list, pick the looping connection, ', ...
            'press Insert Unit Delay.'];
    else
        extraText = 'Read the warnings in the log above.';
    end
    notify(app, sprintf('Model generated with %d warning(s):\n\n%s\n\n%s', ...
        numel(result.Warnings), result.OutputFile, extraText), ...
        'Generation complete - check warnings', 'warning');
end
end

function refreshConnections(~, ~)
modelName = char(strtrim(connModelEdit.Value));
if isempty(modelName)
    modelName = state.LastGeneratedModel;
end
if isempty(modelName)
    setStatus('Enter the generated model name first.');
    return;
end
if ~isvarname(modelName)
    setStatus(sprintf(['"%s" is not a valid model name. Use the model name ', ...
        'only, e.g. "testtcs" - no spaces, dots, or slashes.'], modelName));
    return;
end
if ~bdIsLoaded(modelName)
    insertDelayBtn.Enable = 'off';
    try
        connDropDown.Items = {'(model is not open)'};
    catch
    end
    setStatus(sprintf('Model "%s" is not open in Simulink.', modelName));
    return;
end

try
    [connections, connStats] = listModelConnections(modelName);
catch listError
    insertDelayBtn.Enable = 'off';
    logTo(log1, ['ERROR: ' errorDetails(listError)]);
    notify(app, errorDetails(listError), 'Could not list connections', 'error');
    return;
end

if isempty(connections)
    state.Connections = {};
    try
        connDropDown.Items = {'(no model-to-model connections found)'};
    catch
    end
    insertDelayBtn.Enable = 'off';
    setStatus('No backward connections found in this model.');
    logTo(log1, sprintf(['No backward connections found in "%s" ', ...
        '(only bottom->top / right->left ones are listed; direct ', ...
        'lines and From/Goto links are both detected).\n', ...
        'Diagnostics: %d block(s) in diagram, %d model-reference ', ...
        'block(s), %d connected model output(s), %d Goto block(s), ', ...
        '%d From block(s), %d Unit Delay block(s), %d ambiguous ', ...
        'From/Goto tag(s).\n', ...
        'If this is NOT the generated parent model (its name, e.g. ', ...
        '"testtcs", was filled in automatically after Generate), type ', ...
        'the parent model name and press Refresh list again.'], ...
        modelName, connStats.BlocksScanned, connStats.ModelBlocks, ...
        connStats.ConnectedOutputs, connStats.GotoBlocks, ...
        connStats.FromBlocks, connStats.UnitDelayBlocks, ...
        connStats.AmbiguousTags));
    return;
end

state.Connections = num2cell(connections);
% listModelConnections returns ONLY backward connections (bottom->top
% / right->left) - forward ones never need a Unit Delay.
delayedMask = cellfun(@(c) isfield(c, 'AlreadyDelayed') && c.AlreadyDelayed, ...
    state.Connections);
if chkShowAll.Value
    shownConnections = state.Connections;
    filterMode = 'all';
elseif chkDelayFilter.Value
    shownConnections = state.Connections(delayedMask);
    filterMode = 'withdelay';
else
    shownConnections = state.Connections(~delayedMask);
    filterMode = 'needdelay';
end
if isempty(shownConnections)
    state.Connections = {};
    try
        if strcmp(filterMode, 'withdelay')
            placeholder = '(no connections with a Unit Delay)';
        else
            placeholder = '(every connection already has a Unit Delay)';
        end
        connDropDown.Items = {placeholder};
        connDropDown.Value = placeholder;
    catch
    end
    insertDelayBtn.Enable = 'off';
    if strcmp(filterMode, 'withdelay')
        setStatus('No connections with a Unit Delay (filter is on).');
        logTo(log1, sprintf(['Listed %d connection(s) in "%s" - none of ', ...
            'them has a Unit Delay yet (filter is on).'], ...
            numel(connections), modelName));
    else
        setStatus('Nothing to do: every backward connection already has a Unit Delay.');
        logTo(log1, sprintf(['All %d backward connection(s) in "%s" ', ...
            'already have a Unit Delay.'], ...
            numel(connections), modelName));
    end
    return;
end
labels = cellfun(@(c) c.Label, shownConnections, 'UniformOutput', false);
try
    connDropDown.Items = labels;
    connDropDown.Value = labels{1};
catch
    try
        connDropDown.Value = labels{1};
        connDropDown.Items = labels;
    catch uiError
        logTo(log1, ['ERROR: could not update the connection dropdown: ' ...
            errorDetails(uiError)]);
        notify(app, errorDetails(uiError), ...
            'Could not show the connection list', 'error');
        return;
    end
end
insertDelayBtn.Enable = 'on';
delayedCount = sum(delayedMask);
switch filterMode
    case 'all'
        setStatus(sprintf('%d connection(s) listed (all) - pick one.', ...
            numel(labels)));
        logTo(log1, sprintf(['Listed %d connection(s) in "%s" (all; ', ...
            'model blocks: %d, From/Goto links: %d, already delayed: ', ...
            '%d).'], numel(labels), modelName, connStats.ModelBlocks, ...
            connStats.FromGotoConnections, delayedCount));
    case 'withdelay'
        setStatus(sprintf(['%d of %d connection(s) shown ', ...
            '(with Unit Delay) - pick one.'], numel(labels), ...
            numel(state.Connections)));
        logTo(log1, sprintf(['Listed %d of %d connection(s) in "%s" ', ...
            '(with Unit Delay).'], numel(labels), ...
            numel(state.Connections), modelName));
    otherwise
        setStatus(sprintf(['%d of %d connection(s) need a ', ...
            'Unit Delay - pick one.'], numel(labels), ...
            numel(state.Connections)));
        logTo(log1, sprintf(['Listed %d of %d connection(s) in "%s" ', ...
            '(only those still needing a Unit Delay).'], ...
            numel(state.Connections), modelName));
end
end

function insertDelay(~, ~)
if isempty(state.Connections)
    setStatus('Press Refresh list first.');
    return;
end
selLabel = char(connDropDown.Value);
selIndex = 0;
for cIndex = 1:numel(state.Connections)
    if strcmp(state.Connections{cIndex}.Label, selLabel)
        selIndex = cIndex;
        break;
    end
end
if selIndex == 0
    setStatus('Pick a connection in the list first.');
    return;
end
connection = state.Connections{selIndex};

if isfield(connection, 'Kind') && strcmp(connection.Kind, 'fromgoto')
    kindNote = sprintf(['This is a From/Goto connection: the delay is ', ...
        'placed at the destination model''s input (inport level), ', ...
        'right after the From block of tag "%s" - only this branch ', ...
        'is delayed.'], connection.Tag);
else
    kindNote = ['The delay is placed at the destination model''s ', ...
        'input (inport level), in line with that input port.'];
end
if isfield(connection, 'AlreadyDelayed') && connection.AlreadyDelayed
    kindNote = [kindNote, newline, 'CAUTION: this path already contains ', ...
        'a Unit Delay (inserted automatically). Adding another one here ', ...
        'makes the total delay twice as long (z^-2).'];
end
answer = confirmDialog(app, ...
    sprintf(['Insert a Unit Delay on this connection?\n\n%s\n\n%s'], ...
    connection.Label, kindNote), ...
    'Insert Unit Delay', 'Insert', 'Cancel');
if ~answer
    return;
end

try
    result = insertUnitDelayOnBranch(connection.System, ...
        connection.SrcBlockPath, connection.SrcPortIndex, ...
        connection.DstBlockPath, connection.DstPortIndex, ...
        struct('BlockSpacing', spacingPoints()));
    topModel = strtok(connection.System, '/');
    save_system(topModel);
    % open the system that received the delay so the change is visible
    % (with the main-subsystem wrap, the delay lands inside "model/Core")
    try
        open_system(connection.System);
    catch
    end
    whereText = '';
    if ~strcmp(connection.System, topModel)
        whereText = sprintf(' inside subsystem "%s"', connection.System);
    end
    logTo(log1, result.Message);
    notify(app, sprintf(['%s\n\nThe model has been saved%s.'], ...
        result.Message, whereText), 'Unit Delay inserted', 'success');
    refreshConnections();
catch delayError
    logTo(log1, ['ERROR: ' errorDetails(delayError)]);
    notify(app, errorDetails(delayError), 'Could not insert Unit Delay', 'error');
end
end

function doConfigureSignals(~, ~)
%DOCONFIGURESIGNALS Configure the selected Subsystem's signal objects.

try
    signalReport = configureSubsystemSignals(struct( ...
        'ProcessInports',  logical(chkCfgInports.Value), ...
        'ProcessOutports', logical(chkCfgOutports.Value), ...
        'ShowPropagation', logical(chkCfgPropagation.Value), ...
        'MustResolve',     logical(chkCfgResolver.Value)));
catch cfgError
    logTo(log1, ['ERROR: ' errorDetails(cfgError)]);
    notify(app, errorDetails(cfgError), 'Configure signals failed', 'error');
    setStatus('Configure signals failed - see the log.');
    return;
end

reportLines = {'==== Configure Subsystem Signals ===='};
if isempty(signalReport) || height(signalReport) == 0
    reportLines{end + 1} = 'No Inport or Outport blocks were found.';
else
    % FIX 3: Cast arrays securely to guarantee robust table variable conversions 
    % (handles cell arrays of chars, string arrays, categorical and numerical arrays)
    dirCol  = string(signalReport.Direction);
    portCol = double(signalReport.Port);
    sigCol  = string(signalReport.Signal);
    statCol = string(signalReport.Status);
    
    for rowIndex = 1:height(signalReport)
        reportLines{end + 1} = sprintf('%s %g "%s": %s', ...
            dirCol(rowIndex), ...
            portCol(rowIndex), ...
            sigCol(rowIndex), ...
            statCol(rowIndex)); %#ok<AGROW>
    end
    reportLines{end + 1} = sprintf( ...
        ['Configured: %d | Skipped: %d | Failed: %d ', ...
         '(full details in the Command Window)'], ...
        sum(statCol == "Configured"), ...
        sum(statCol == "Skipped"), ...
        sum(statCol == "Failed"));
end
logMany(log1, reportLines);
setStatus('Subsystem signals configured - see the log above.');
notify(app, ['Subsystem signal configuration finished.\n\n', ...
    'The summary is in the log above; the full per-port report is in ', ...
    'the Command Window.'], 'Configure signals', 'info');
end

% =========================================================================
%  NESTED CALLBACKS - TAB 2
% =========================================================================
function refreshSubsystem(~, ~)
try
    ports = getSubsystemPorts();
    subsystemLabel.Text = ports.Path;
    subsystemLabel.FontColor = [0 0 0];
    safeTooltip(subsystemLabel, ports.Path);
    items = {};
    for portIndex = 1:numel(ports.InportNames)
        items{end + 1} = ['IN   ' ports.InportNames{portIndex}]; %#ok<AGROW>
    end
    for portIndex = 1:numel(ports.OutportNames)
        items{end + 1} = ['OUT  ' ports.OutportNames{portIndex}]; %#ok<AGROW>
    end
    if isempty(items)
        items = {'(no ports found)'};
    end
    tagsList.Items = items;
    tagsList.Value = items{1};
    setStatus('Subsystem selected.');
    logTo(log2, ['Subsystem selected: ' ports.Path]);
catch selectionError
    subsystemLabel.Text = '<no subsystem selected>';
    subsystemLabel.FontColor = [0.75 0 0];
    tagsList.Items = {};
    setStatus('Select a subsystem in Simulink, then press Refresh.');
    logTo(log2, ['Selection: ' selectionError.message]);
end
end

function browseSearchFolder(~, ~)
startFolder = pwd;
candidate = char(strtrim(searchEdit.Value));
if isfolder(candidate)
    startFolder = candidate;
end
chosenFolder = uigetdir(startFolder, ...
    'Select the parent folder containing the .m files');
bringAppToFront();
if isequal(chosenFolder, 0)
    return;
end
searchEdit.Value = chosenFolder;
setpref('teamtools', 'SearchFolder', chosenFolder);
end

function browseOutputFile(~, ~)
initialFile = fullfile(pwd, 'ExtractedAttributes.m');
candidate = char(strtrim(searchEdit.Value));
if isfolder(candidate)
    initialFile = fullfile(candidate, 'ExtractedAttributes.m');
end
[name, folder] = uiputfile({'*.m', 'MATLAB files (*.m)'}, ...
    'Select the destination MATLAB file', initialFile);
bringAppToFront();
if isequal(name, 0) || isequal(folder, 0)
    return;
end
[~, baseName, extension] = fileparts(name);
if isempty(extension)
    name = [baseName '.m'];
elseif ~strcmpi(extension, '.m')
    notify(app, 'The destination must be a .m file.', ...
        'Invalid destination', 'error');
    return;
end
outputFile = fullfile(folder, name);
destEdit.Value = outputFile;
setpref('teamtools', 'OutputFile', outputFile);
end

function doExtract(~, ~)
try
    ports = getSubsystemPorts();
catch selectionError
    notify(app, selectionError.message, 'No subsystem selected', 'warning');
    return;
end
subsystemLabel.Text = ports.Path;
subsystemLabel.FontColor = [0 0 0];

searchFolder = char(strtrim(searchEdit.Value));
if ~isfolder(searchFolder)
    notify(app, 'Choose a valid search folder first (Browse...).', ...
        'Missing folder', 'warning');
    return;
end

outputFile = char(strtrim(destEdit.Value));
[~, ~, outputExtension] = fileparts(outputFile);
if isempty(outputFile) || ~strcmpi(outputExtension, '.m')
    notify(app, 'The destination file must end with .m.', ...
        'Invalid destination', 'warning');
    return;
end
outputFolder = fileparts(outputFile);
if isempty(outputFolder)
    outputFile = fullfile(pwd, outputFile);
elseif ~isfolder(outputFolder)
    notify(app, 'The destination folder does not exist.', ...
        'Invalid destination', 'warning');
    return;
end

infoChoice = infoDropDown.Value;
switch infoChoice
    case 'Header only'
        includeMetadata = true;
        includeComments = false;
    case 'Source comments only'
        includeMetadata = false;
        includeComments = true;
    otherwise
        includeMetadata = true;
        includeComments = true;
end

options = struct( ...
    'PortChoice',            portDropDown.Value, ...
    'IncludeMetadata',       includeMetadata, ...
    'IncludeSourceComments', includeComments, ...
    'CaseInsensitive',       chkCase2.Value);

setStatus('Extracting...');
extractBtn.Enable = 'off';
p = makeProgress(app, 'Extracting attributes');
try
    options.ProgressFcn = @(fraction, message) p.set(fraction, message);
    options.CancelRequestedFcn = @() p.cancelled();
    result = extractAttributesCore(ports.Handle, searchFolder, outputFile, options);
    p.close();
catch extractError
    p.close();
    extractBtn.Enable = 'on';
    setStatus('Extraction failed.');
    logTo(log2, ['ERROR: ' errorDetails(extractError)]);
    notify(app, errorDetails(extractError), 'Extraction failed', 'error');
    return;
end
extractBtn.Enable = 'on';

if result.Cancelled
    setStatus('Extraction cancelled.');
    logTo(log2, 'Extraction cancelled by user - no file was written.');
    return;
end

state.ExtractOutput = result.OutputFile;
setpref('teamtools', 'OutputFile', result.OutputFile);
openOutputBtn.Enable = 'on';
openFolderBtn.Enable = 'on';

logMany(log2, renderExtractSummary(result));
setStatus('Extraction complete.');
notify(app, sprintf(['Extraction complete.\n\nFiles read: %d\n', ...
    'Unique records: %d\n\nOutput:\n%s\n\nCheck the log for ', ...
    'per-tag counts.'], result.FilesRead, result.UniqueMatches, ...
    result.OutputFile), 'Extraction complete', 'success');
end

function openOutputFile(~, ~)
if isempty(state.ExtractOutput)
    return;
end
try
    open(state.ExtractOutput);
catch
    setStatus('Could not open the output file.');
end
end

function openOutputFolder(~, ~)
if isempty(state.ExtractOutput)
    return;
end
try
    open(fileparts(state.ExtractOutput));
catch
    setStatus('Could not open the output folder.');
end
end

function browseConvertPath(~, ~)
%BROWSECONVERTPATH Pick the convert_m_to_sldd.m file.

[pickedFile, pickedPath] = uigetfile('*.m', ...
    'Pick convert_m_to_sldd.m');
bringAppToFront();
if isequal(pickedFile, 0)
    return;
end
convertPathEdit.Value = fullfile(pickedPath, pickedFile);
setpref('teamtools', 'ConvertPath', convertPathEdit.Value);
end

function browseSlddDest(~, ~)
%BROWSESLDDDEST Pick the folder the .sldd files are moved to.

pickedFolder = uigetdir(pwd, 'Pick the folder for the .sldd file(s)');
bringAppToFront();
if isequal(pickedFolder, 0)
    return;
end
slddDestEdit.Value = pickedFolder;
setpref('teamtools', 'SlddDestFolder', pickedFolder);
end

function doConvertToSldd(~, ~)
%DOCONVERTTOSLDD Run the team's convert_m_to_sldd on the extracted file.

convertPath = char(strtrim(convertPathEdit.Value));
if isempty(convertPath)
    notify(app, ['Enter the path of convert_m_to_sldd.m (or its ', ...
        'folder) first - use Browse... to pick it.'], ...
        'Missing path', 'warning');
    return;
end

% the conversion input: the extracted attributes .m file
mFile = state.ExtractOutput;
if isempty(mFile) || ~isfile(mFile)
    candidate = char(strtrim(destEdit.Value));
    if ~isempty(candidate) && isfile(candidate)
        mFile = candidate;
    end
end
if isempty(mFile) || ~isfile(mFile)
    notify(app, ['Extract the attributes first - the extracted .m ', ...
        'file is the input for the conversion (or point the ', ...
        'destination file at an existing .m).'], ...
        'No extracted file', 'warning');
    return;
end

% the path field accepts the folder OR the .m file itself
if isfolder(convertPath)
    convertFolder = convertPath;
elseif isfile(convertPath)
    convertFolder = fileparts(convertPath);
else
    notify(app, sprintf('The path does not exist:\n%s', convertPath), ...
        'Invalid path', 'error');
    return;
end
addpath(convertFolder);
if exist('convert_m_to_sldd', 'file') ~= 2
    notify(app, sprintf(['convert_m_to_sldd.m was not found in:\n%s\n\n', ...
        'Check the path (the file or its folder).'], convertFolder), ...
        'Function not found', 'error');
    return;
end
setpref('teamtools', 'ConvertPath', convertPath);

% call it the way it is declared: a 0-input function is called without
% arguments, otherwise the extracted file is passed; a plain script
% (nargin fails) is run as-is
try
    declaredInputs = nargin('convert_m_to_sldd');
catch
    declaredInputs = -1;
end
if declaredInputs <= 0
    logTo(log2, ['NOTE: this convert_m_to_sldd takes no input - it ', ...
        'scans its own root folder and may ignore the extracted ', ...
        'file. If it creates nothing, check the root setting ', ...
        'inside convert_m_to_sldd.m.']);
end

% resolve where the created .sldd files must end up: the field,
% else the folder of the .m file - never the MATLAB current folder
slddDest = char(strtrim(slddDestEdit.Value));
if isfile(slddDest)
    slddDest = fileparts(slddDest);
end
if isempty(slddDest)
    slddDest = fileparts(mFile);
end
slddDest = absFolder(slddDest);
if ~isempty(char(strtrim(slddDestEdit.Value)))
    setpref('teamtools', 'SlddDestFolder', ...
        char(strtrim(slddDestEdit.Value)));
end
if ~isfolder(slddDest)
    logTo(log2, sprintf(['WARNING: "Save .sldd in" is not a folder:', ...
        '\n  %s\nThe .sldd file(s) stay where the team function ', ...
        'put them.'], slddDest));
    slddDest = '';
end

% remember which .sldd files already exist, so the ones this run
% creates (or overwrites) can be moved to the destination
slddWatch = unique({absFolder(pwd); absFolder(fileparts(mFile)); ...
    absFolder(convertFolder)});
if ~isempty(slddDest)
    slddWatch = unique([slddWatch; {slddDest}]);
end
slddBefore = struct('Path', {}, 'Modified', {});
for slddWatchIndex = 1:numel(slddWatch)
    slddBefore = [slddBefore, ...
        slddFilesIn(slddWatch{slddWatchIndex})]; %#ok<AGROW>
end

setStatus('Running convert_m_to_sldd...');
try
    if declaredInputs == 0
        convert_m_to_sldd();
        callText = 'convert_m_to_sldd()';
    elseif declaredInputs == -1
        convert_m_to_sldd; %#ok<NASGU>
        callText = 'convert_m_to_sldd';
    else
        convert_m_to_sldd(mFile);
        callText = sprintf('convert_m_to_sldd(''%s'')', mFile);
    end
catch convertError
    logTo(log2, ['ERROR: ' errorDetails(convertError)]);
    notify(app, errorDetails(convertError), ...
        'convert_m_to_sldd failed', 'error');
    setStatus('Conversion failed - see the log.');
    return;
end
logTo(log2, sprintf('%s finished on:\n  %s', callText, mFile));

% the .sldd files this run created or overwrote
slddCreated = {};
for slddWatchIndex = 1:numel(slddWatch)
    slddNow = slddFilesIn(slddWatch{slddWatchIndex});
    for slddFileIndex = 1:numel(slddNow)
        slddMatch = find(strcmp({slddBefore.Path}, ...
            slddNow(slddFileIndex).Path), 1);
        if isempty(slddMatch) || ...
                slddNow(slddFileIndex).Modified > ...
                slddBefore(slddMatch).Modified
            slddCreated{end + 1} = ...
                slddNow(slddFileIndex).Path; %#ok<AGROW>
        end
    end
end

if isempty(slddCreated)
    logTo(log2, ['No new or updated .sldd file was detected (looked ', ...
        'in the current folder, the .m folder, the convert function ', ...
        'folder and the destination - subfolders included). If the ', ...
        'team function writes somewhere else, move it manually.']);
    setStatus('Conversion finished - no .sldd detected.');
    notify(app, sprintf(['%s finished, but no new .sldd file was ', ...
        'detected.\n\nDetails are in the log.'], callText), ...
        'Convert to .sldd', 'warning');
    return;
end

slddLines = {};
slddAllMoved = ~isempty(slddDest);
for slddCreatedIndex = 1:numel(slddCreated)
    [slddFileFolder, slddFileName] = ...
        fileparts(slddCreated{slddCreatedIndex});
    if isempty(slddDest) || strcmpi(slddFileFolder, slddDest)
        slddLines{end + 1} = sprintf('  %s  (in %s)', ...
            slddFileName, slddFileFolder); %#ok<AGROW>
    else
        slddTarget = fullfile(slddDest, slddFileName);
        try
            if isfile(slddTarget)
                delete(slddTarget);
            end
            movefile(slddCreated{slddCreatedIndex}, slddTarget);
            slddLines{end + 1} = sprintf('  %s  moved to %s', ...
                slddFileName, slddDest); %#ok<AGROW>
        catch slddMoveError
            slddAllMoved = false;
            slddLines{end + 1} = sprintf( ...
                '  %s  could NOT be moved to %s (%s)', ...
                slddFileName, slddDest, slddMoveError.message); %#ok<AGROW>
        end
    end
end
logTo(log2, sprintf('.sldd file(s) created by this run:\n%s', ...
    strjoin(slddLines, newline)));
if isempty(slddDest) || ~slddAllMoved
    setStatus('Conversion finished - check the log for the .sldd.');
    notify(app, sprintf(['%s finished.\n\nThe .sldd location is in ', ...
        'the log.'], callText), 'Convert to .sldd', 'warning');
else
    setStatus(sprintf('%d .sldd file(s) in: %s', ...
        numel(slddCreated), slddDest));
    notify(app, sprintf(['%s finished.\n\n%d .sldd file(s) are ', ...
        'in:\n%s'], callText, numel(slddCreated), slddDest), ...
        'Convert to .sldd', 'success');
end
end

end

% =========================================================================
%  LOCAL FUNCTIONS
% =========================================================================
function ports = getSubsystemPorts(subsystemHandle)
%GETSUBSYSTEMPORTS Immediate Inport/Outport names of a Simulink subsystem.

if nargin < 1 || isempty(subsystemHandle)
    subsystemHandle = gcbh;
end

if isempty(subsystemHandle) || ~isnumeric(subsystemHandle) || ...
        ~isscalar(subsystemHandle) || subsystemHandle == 0 || subsystemHandle == -1
    error('getSubsystemPorts:NoSelection', ...
        ['No Simulink block is selected. Open the model, click the ', ...
         'required subsystem, then press Refresh.']);
end

try
    blockType = get_param(subsystemHandle, 'BlockType');
catch
    error('getSubsystemPorts:NoSelection', ...
        ['The selected block is no longer available. Open the model, ', ...
         'click the required subsystem, then press Refresh.']);
end

if ~strcmp(blockType, 'SubSystem')
    error('getSubsystemPorts:NotSubsystem', ...
        'The selected block is not a subsystem: %s', ...
        getfullname(subsystemHandle));
end

commonOptions = {'LookUnderMasks', 'on', 'FollowLinks', 'on', 'SearchDepth', 1};

inportHandles = find_system(subsystemHandle, commonOptions{:}, ...
    'BlockType', 'Inport');
outportHandles = find_system(subsystemHandle, commonOptions{:}, ...
    'BlockType', 'Outport');

ports = struct();
ports.Handle = double(subsystemHandle);
ports.Path = getfullname(subsystemHandle);
ports.InportNames = normalizeSubsystemBlockNames(inportHandles);
ports.OutportNames = normalizeSubsystemBlockNames(outportHandles);
end

function names = normalizeSubsystemBlockNames(blockHandles)
if isempty(blockHandles)
    names = {};
    return;
end
names = get_param(blockHandles, 'Name');
if ischar(names)
    names = {names};
end
names = cellfun(@strtrim, names, 'UniformOutput', false);
names = names(~cellfun('isempty', names));
names = unique(names, 'stable');
names = names(:).';
end
function p = makeProgress(appFigure, title)
%MAKEPROGRESS Progress dialog with version-safe cancel support.

cancelable = true;
try
    dialogHandle = uiprogressdlg(appFigure, 'Title', title, ...
        'Message', 'Preparing...', 'Indeterminate', 'on', 'Cancelable', 'on');
catch
    dialogHandle = uiprogressdlg(appFigure, 'Title', title, ...
        'Message', 'Preparing...', 'Indeterminate', 'on');
    cancelable = false;
end

p.set = @(fraction, message) progressSet(dialogHandle, fraction, message);
p.cancelled = @() progressCancelled(dialogHandle, cancelable);
p.close = @() progressClose(dialogHandle);
end

function progressSet(dialogHandle, fraction, message)
if isvalid(dialogHandle)
    try
        dialogHandle.Indeterminate = 'off';
        dialogHandle.Value = fraction;
        dialogHandle.Message = char(message);
    catch
    end
    drawnow limitrate;
end
end

function tf = progressCancelled(dialogHandle, cancelable)
tf = false;
if cancelable && isvalid(dialogHandle) && isprop(dialogHandle, 'CancelRequested')
    tf = logical(dialogHandle.CancelRequested);
end
end

function progressClose(dialogHandle)
if ~isempty(dialogHandle) && isvalid(dialogHandle)
    close(dialogHandle);
end
end

function notify(appFigure, message, title, icon)
%NOTIFY Alert dialog with graceful fallbacks on older releases.

try
    uialert(appFigure, char(message), title, 'Icon', icon);
catch
    try
        uialert(appFigure, char(message), title, 'Icon', 'info');
    catch
        msgbox(char(message), title);
    end
end
end

function safeTooltip(component, text)
%SAFETOOLTIP Set a tooltip when the release supports it.

try
    component.Tooltip = char(text);
catch
end
end

function tf = confirmDialog(appFigure, message, title, okLabel, cancelLabel)
%CONFIRMDIALOG Two-button confirm dialog for any MATLAB release.
%uiconfirm renamed its options around R2021a ('Buttons'/'DefaultButton'
%became 'Options'/'DefaultOption'/'CancelOption'), so try the old names,
%then the new names, then fall back to questdlg, which works everywhere.

tf = false;
try
    tf = dialogChoice(uiconfirm(appFigure, char(message), char(title), ...
        'Buttons', {okLabel, cancelLabel}, ...
        'DefaultButton', cancelLabel, ...
        'CancelButton', cancelLabel, ...
        'Icon', 'warning'), okLabel);
    return;
catch
end
try
    tf = dialogChoice(uiconfirm(appFigure, char(message), char(title), ...
        'Options', {okLabel, cancelLabel}, ...
        'DefaultOption', cancelLabel, ...
        'CancelOption', cancelLabel, ...
        'Icon', 'warning'), okLabel);
    return;
catch
end
try
    answer = questdlg(char(message), char(title), ...
        char(okLabel), char(cancelLabel), char(cancelLabel));
    tf = strcmp(char(answer), char(okLabel));
catch
    tf = false;
end
end

function tf = dialogChoice(answer, okLabel)
%DIALOGCHOICE Extract the pressed button from a uiconfirm response.

if isstruct(answer) && isfield(answer, 'SelectedButton')
    tf = strcmp(char(answer.SelectedButton), char(okLabel));
elseif ischar(answer)
    tf = strcmp(answer, char(okLabel));
else
    tf = false;
end
end

function location = errorLocation(err)
%ERRORLOCATION Short "function, line N" description of an error's origin.

location = '';
try
    if isstruct(err) && isfield(err, 'stack') && ~isempty(err.stack)
        location = sprintf('%s, line %d', err.stack(1).name, ...
            err.stack(1).line);
    end
catch
end
end

function details = errorDetails(err)
%ERRORDETAILS Message plus the full cause chain of an error.
%Simulink failures often report "Error due to multiple causes." with the
%real reason hidden in err.cause - this surfaces everything.

details = strtrim(char(err.message));
if isempty(details)
    details = '(no message)';
end
for groupIndex = 1:numel(err.cause)
    causeGroup = err.cause{groupIndex};
    for causeIndex = 1:numel(causeGroup)
        causeText = strtrim(char(causeGroup(causeIndex).message));
        if ~isempty(causeText)
            details = [details newline '   caused by: ' causeText]; %#ok<AGROW>
        end
    end
end
% Simulink messages contain clickable hyperlinks like
% <a href="matlab:...">name</a> - keep only the visible text.
details = regexprep(details, '<a[^>]*>\s*([^<]*?)\s*</a>', '$1');

location = errorLocation(err);
if isempty(location)
    for groupIndex = 1:numel(err.cause)
        causeGroup = err.cause{groupIndex};
        for causeIndex = 1:numel(causeGroup)
            if ~isempty(causeGroup(causeIndex).stack)
                location = errorLocation(causeGroup(causeIndex));
                break;
            end
        end
        if ~isempty(location)
            break;
        end
    end
end
if ~isempty(location)
    details = [details '   [' location ']'];
end
end

function values = asCell(value)
%ASCELL Listbox Value as a row cell array (handles single and multi mode).

if isempty(value)
    values = {};
elseif ischar(value)
    values = {value};
else
    values = value(:)';
end
end

function enableMultiSelect(listBox)
%ENABLEMULTISELECT Turn on multi-selection where the release supports it.
% The documented property name is 'Multiselect' (lowercase s). Dot
% access is case-sensitive, so a wrong spelling silently disables
% multi-selection - try several routes and stay quiet when the release
% has no multi-select list box at all (R2020a).

try
    listBox.Multiselect = 'on';
    return;
catch
end
try
    set(listBox, 'Multiselect', 'on');   % case-insensitive route
    return;
catch
end
try
    listBox.MultiSelect = 'on';          % alternate spelling, just in case
catch
end
end

function v = gapValue(editField, fallback, prefKey, minValue)
%GAPVALUE Read one spacing field: fallback when empty, minimum kept,
% and the value is remembered in the preferences.

try
    v = round(double(editField.Value));
catch
    v = fallback;
end
if isempty(v) || isnan(v) || v < minValue
    v = fallback;
end
try
    setpref('teamtools', prefKey, v);
catch
end
end

function out = absFolder(in)
%ABSFOLDER Absolute, tidied version of a folder path (for compare).

in = char(strtrim(in));
if isempty(in)
    out = pwd;
    return;
end
if (numel(in) >= 2 && in(2) == ':') || in(1) == filesep
    out = in;
else
    out = fullfile(pwd, in);
end
% drop trailing file separators and trailing '.' segments
% ('C:\work\.' -> 'C:\work'), but never touch ordinary names
while numel(out) > 3
    if out(end) == filesep
        out = out(1:end-1);
    elseif out(end) == '.' && out(end-1) == filesep
        out = out(1:end-1);
        if out(end) == filesep
            out = out(1:end-1);
        end
    else
        break;
    end
end
end

function files = slddFilesIn(folder)
%SLDDFILESIN The .sldd files in a folder with their modification times.

files = struct('Path', {}, 'Modified', {});
if isfolder(folder)
    % '**' also finds .sldd files in SUBFOLDERS (e.g. a root folder
    % the team function uses inside the current folder)
    listing = dir(fullfile(folder, '**', '*.sldd'));
    for fileIndex = 1:numel(listing)
        if ~listing(fileIndex).isdir
            files(end + 1) = struct( ...
                'Path', fullfile(listing(fileIndex).folder, ...
                listing(fileIndex).name), ...
                'Modified', listing(fileIndex).datenum); %#ok<AGROW>
        end
    end
end
end

function tf = cacheFolderWritable(folder)
%CACHEFOLDERWRITABLE True when files can be created in the folder.

tf = false;
try
    probeFile = fullfile(folder, 'teamtools_probe.tmp');
    probeId = fopen(probeFile, 'w');
    if probeId > 0
        fclose(probeId);
        delete(probeFile);
        tf = true;
    end
catch
end
end

function setListSelection(list, values, wasChar)
%SETLISTSELECTION Set a list selection safely in single- or multi-select mode.

if isempty(values)
    return;
end
if wasChar
    list.Value = values{1};
else
    try
        list.Value = values;
    catch
        list.Value = values{1};
    end
end
end

function logTo(area, message)
%LOGTO Append one timestamped line to a log area.
% The same line is echoed to the command window so the session
% diary (log.txt, started at app launch) records it too.

stamp = char(datetime('now', 'Format', 'HH:mm:ss'));
text = [stamp, '  ', char(message)];
try
    fprintf('%s\n', text);
catch
end
lines = area.Value;
if ischar(lines)
    lines = {lines};
end
lines = [lines; {text}]; %#ok<AGROW>
if numel(lines) > 500
    lines = lines(end - 499:end);
end
area.Value = lines;
drawnow limitrate;
end

function logMany(area, newLines)
%LOGMANY Append a block of lines to a log area.
% The block is echoed to the command window so the session diary
% (log.txt, started at app launch) records it too.

if isempty(newLines)
    return;
end
lines = area.Value;
if ischar(lines)
    lines = {lines};
end
stamp = char(datetime('now', 'Format', 'HH:mm:ss'));
lines = [lines; {['---- ', stamp, ' ----']}; newLines(:)];
if numel(lines) > 500
    lines = lines(end - 499:end);
end
area.Value = lines;
try
    fprintf('---- %s ----\n', stamp);
    fprintf('%s\n', newLines{:});
catch
end
drawnow limitrate;
end

function files = discoverModelFiles(folder)
%DISCOVERMODELFILES .slx/.mdl files under a folder (recursive).

slxFiles = dir(fullfile(folder, '**', '*.slx'));
mdlFiles = dir(fullfile(folder, '**', '*.mdl'));
files = [slxFiles; mdlFiles];
end

function relativePart = relativePart(fullPath, rootFolder)
%RELATIVEPART Subfolder part of fullPath relative to rootFolder ('' if none).

rootWithSeparator = [char(rootFolder) filesep];
if strncmpi(fullPath, rootWithSeparator, numel(rootWithSeparator))
    relativePart = fullPath(numel(rootWithSeparator) + 1:end);
    cutAt = strfind(relativePart, filesep);
    if ~isempty(cutAt)
        relativePart = relativePart(1:cutAt(end) - 1);
    end
else
    relativePart = '';
end
end

function lines = renderPlanLines(result)
%RENDERPLANLINES Human-readable preview of the generator plan.

lines = {};
lines{end + 1} = '================ PREVIEW ================';
lines{end + 1} = sprintf('Generated model: %s (not created yet)', ...
    result.TargetModel);
for modelIndex = 1:numel(result.Models)
    model = result.Models(modelIndex);
    lines{end + 1} = sprintf('  %d. %-20s %d in, %d out', modelIndex, ...
        model.Name, numel(model.InputNames), numel(model.OutputNames));
end
if ~isempty(result.ConfigParamNames)
    lines{end + 1} = 'Configuration (all referenced models match):';
    for paramIndex = 1:numel(result.ConfigParamNames)
        lines{end + 1} = sprintf('  %s = %s', ...
            result.ConfigParamNames{paramIndex}, ...
            result.ConfigParamValues{paramIndex});
    end
end
lines{end + 1} = sprintf('Internal connections (%d):', result.Counts.Internal);
for connectionIndex = 1:numel(result.InternalConnections)
    connection = result.InternalConnections(connectionIndex);
    lines{end + 1} = sprintf('  %s.%s  -->  %s.%s', ...
        connection.SrcModel, connection.SrcPort, ...
        connection.DstModel, connection.DstPort);
end
lines{end + 1} = sprintf('Root inputs (%d):', result.Counts.RootInputs);
for inputIndex = 1:numel(result.RootInputs)
    lines{end + 1} = sprintf('  %s  (feeds: %s)', ...
        result.RootInputs(inputIndex).Name, ...
        strjoin(result.RootInputs(inputIndex).DestinationModels(:), ', '));
end
lines{end + 1} = sprintf('Root outputs (%d):', result.Counts.RootOutputs);
for outputIndex = 1:numel(result.RootOutputs)
    lines{end + 1} = sprintf('  %s  (from %s.%s)', ...
        result.RootOutputs(outputIndex).Name, ...
        result.RootOutputs(outputIndex).SourceModel, ...
        result.RootOutputs(outputIndex).SourcePort);
end
if ~isempty(result.Notes)
    lines{end + 1} = 'Notes:';
    for noteIndex = 1:numel(result.Notes)
        lines{end + 1} = ['  - ' result.Notes{noteIndex}];
    end
end
if isempty(result.Warnings)
    lines{end + 1} = 'No warnings.';
else
    lines{end + 1} = 'Warnings:';
    for warningIndex = 1:numel(result.Warnings)
        lines{end + 1} = ['  - ' result.Warnings{warningIndex}];
    end
end
lines{end + 1} = '==========================================';
end

function lines = renderExtractSummary(result)
%RENDEREXTRACTSUMMARY Human-readable extraction summary.

lines = {};
lines{end + 1} = sprintf('Extraction finished for: %s', result.Subsystem);
lines{end + 1} = sprintf('Files found: %d | read: %d | skipped: %d', ...
    result.FilesFound, result.FilesRead, result.FilesSkipped);
lines{end + 1} = sprintf('Unique records written: %d', result.UniqueMatches);
lines{end + 1} = 'Records per tag:';
for tagIndex = 1:numel(result.Tags)
    marker = '';
    if result.Tags(tagIndex).Count == 0
        marker = '   <-- no records found (check the port name)';
    end
    lines{end + 1} = sprintf('   %-25s %d%s', result.Tags(tagIndex).Name, ...
        result.Tags(tagIndex).Count, marker);
end
lines{end + 1} = ['Output: ' result.OutputFile];
if ~isempty(result.Warnings)
    lines{end + 1} = 'Warnings:';
    for warningIndex = 1:numel(result.Warnings)
        lines{end + 1} = ['   - ' result.Warnings{warningIndex}];
    end
end
end

function position = centeredPosition(width, height)
%CENTEREDPOSITION Screen-centered figure position.

screenSize = get(groot, 'ScreenSize');
left = max(1, round((screenSize(3) - width) / 2));
bottom = max(1, round((screenSize(4) - height) / 2));
position = [left bottom width height];
end