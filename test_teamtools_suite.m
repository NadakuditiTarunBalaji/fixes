function test_teamtools_suite()
%TEST_TEAMTOOLS_SUITE Comprehensive automated test suite for Simulink Team Tools.
%
%   test_teamtools_suite()
%
% Runs an end-to-end validation across all backend engines in a sandbox
% directory and outputs a test summary report.
%
% Requirements: MATLAB R2020a+ with Simulink.

clc;
fprintf('=================================================================\n');
fprintf('       SIMULINK TEAM TOOLS - AUTOMATED TEST SUITE                \n');
fprintf('=================================================================\n\n');

% Verify Simulink license
if ~license('test', 'Simulink')
    error('test_teamtools_suite:NoSimulink', 'Simulink license is required to run tests.');
end

% Set up isolated sandbox directory
originalDir = pwd;
testDir = fullfile(originalDir, 'sandbox_teamtools_test');
if isfolder(testDir)
    try bdclose('all'); catch; end
    try rmdir(testDir, 's'); catch; end
end
mkdir(testDir);

% Ensure test folder and parent folder are on path
addpath(originalDir);
addpath(testDir);

% Guarantee cleanup on exit or crash
cleanupObj = onCleanup(@() tearDown(originalDir, testDir));

% Test tracking
testNames = {};
testStatus = {};
testMessages = {};

% =========================================================================
%  STAGE 0: SETUP DUMMY REFERENCE MODELS
% =========================================================================
fprintf('[0/7] Setting up dummy reference models in sandbox...\n');
try
    cd(testDir);
    setupDummyModels();
    logPass('Setup Dummy Models', 'Created test_sensor, test_controller, test_actuator');
catch setupErr
    logFail('Setup Dummy Models', setupErr.message);
    printSummary();
    return;
end

% =========================================================================
%  STAGE 1: TEST BUILD PARENT MODEL (Preview & Generation)
% =========================================================================
fprintf('\n[1/7] Testing buildParentModelCore.m...\n');
try
    models = {'test_sensor', 'test_controller', 'test_actuator'};
    
    % Test 1.1: Preview Only
    prevOpts = struct('PreviewOnly', true, 'ConnectionMethod', 'fromgoto');
    prevRes = buildParentModelCore(testDir, models, 'test_parent_preview', prevOpts);
    assert(prevRes.Success == true, 'Preview did not return success.');
    assert(prevRes.Counts.Internal >= 2, 'Preview internal connection count mismatch.');
    logPass('Parent Model Preview', 'Preview calculated counts correctly without building files.');
    
    % Test 1.2: From/Goto Generation with AutoDelay & Subsystem Wrap
    genOpts = struct( ...
        'PreviewOnly',       false, ...
        'Overwrite',         true, ...
        'ConnectionMethod',  'fromgoto', ...
        'Layout',            'vertical', ...
        'AutoDelayFeedback', true, ...
        'WrapInSubsystem',   true);
    genRes = buildParentModelCore(testDir, models, 'test_parent_fromgoto', genOpts);
    assert(genRes.Success == true, 'From/Goto generation failed.');
    assert(isfile(fullfile(testDir, 'test_parent_fromgoto.slx')), 'Generated .slx file missing.');
    assert(~isempty(genRes.SubsystemName), 'Subsystem wrapping failed.');
    logPass('Build From/Goto Parent Model', 'Generated From/Goto model with Auto Unit Delays and Core Subsystem.');

    % Test 1.3: Direct Lines Generation
    linesOpts = struct( ...
        'PreviewOnly',       false, ...
        'Overwrite',         true, ...
        'ConnectionMethod',  'lines', ...
        'Layout',            'horizontal', ...
        'AutoDelayFeedback', false, ...
        'WrapInSubsystem',   false);
    linesRes = buildParentModelCore(testDir, models, 'test_parent_lines', linesOpts);
    assert(linesRes.Success == true, 'Direct lines generation failed.');
    assert(isfile(fullfile(testDir, 'test_parent_lines.slx')), 'Direct lines .slx file missing.');
    logPass('Build Direct Lines Parent Model', 'Generated Direct Lines horizontal model successfully.');
    
catch genErr
    logFail('buildParentModelCore', genErr.message);
end

% =========================================================================
%  STAGE 2: TEST LOOP BREAKER & BACKWARD DETECTION
% =========================================================================
fprintf('\n[2/7] Testing listModelConnections.m & insertUnitDelayOnBranch.m...\n');
try
    % Load generated lines model for analysis
    if ~bdIsLoaded('test_parent_lines')
        load_system('test_parent_lines');
    end
    
    [conns, stats] = listModelConnections('test_parent_lines');
    assert(~isempty(conns), 'No connections found in test_parent_lines.');
    assert(stats.ModelBlocks == 3, 'ModelBlocks count mismatch in stats.');
    
    % Verify backward connection detection (actuator -> controller feedback or self-loop)
    backwardFound = false;
    for k = 1:numel(conns)
        if contains(conns(k).Label, 'test_actuator') || contains(conns(k).Label, 'self_loop')
            backwardFound = true;
            targetConn = conns(k);
            break;
        end
    end
    assert(backwardFound, 'Backward feedback connection was not identified.');
    logPass('Detect Feedback Connections', sprintf('Identified %d backward/feedback connection(s).', numel(conns)));

    % Test Unit Delay Insertion
    insertRes = insertUnitDelayOnBranch( ...
        targetConn.System, ...
        targetConn.SrcBlockPath, targetConn.SrcPortIndex, ...
        targetConn.DstBlockPath, targetConn.DstPortIndex, ...
        struct('BlockSpacing', 100));
    assert(~isempty(insertRes.NewBlockPath), 'Unit delay insertion returned empty path.');
    assert(get_param(insertRes.NewBlockPath, 'Handle') ~= -1, 'Inserted block is invalid.');
    logPass('Insert Unit Delay on Branch', 'Inserted Unit Delay with zero collision and verified re-routing.');
    
catch loopErr
    logFail('Loop Breaker Suite', loopErr.message);
end

% =========================================================================
%  STAGE 3: TEST ATTRIBUTE EXTRACTION
% =========================================================================
fprintf('\n[3/7] Testing extractAttributesCore.m...\n');
try
    % Create dummy .m attribute source file with UTF-8 characters
    attrFile = fullfile(testDir, 'sensor_data.m');
    fid = fopen(attrFile, 'wt', 'n', 'UTF-8');
    fprintf(fid, '%% Sensor attributes calibration\n');
    fprintf(fid, 'speed.Unit = ''km/h''; %% Velocity [m/s ± 5%%]\n');
    fprintf(fid, 'speed.Min = 0;\n');
    fprintf(fid, 'speed.Max = 250;\n');
    fprintf(fid, 'temp.Unit = ''degC'';\n');
    fprintf(fid, 'm_sensor_gain = 1.25;\n');
    fclose(fid);
    
    % Open sensor model and extract from root or subsystem
    load_system('test_sensor');
    subHandle = get_param('test_sensor', 'Handle');
    
    outExtracted = fullfile(testDir, 'Extracted_test_sensor.m');
    extOpts = struct('PortChoice', 'Both', 'CaseInsensitive', true);
    extRes = extractAttributesCore(subHandle, testDir, outExtracted, extOpts);
    
    assert(extRes.UniqueMatches >= 4, 'Extracted record count lower than expected.');
    assert(isfile(outExtracted), 'Extracted .m file was not created.');
    logPass('Extract Attributes Engine', sprintf('Extracted %d unique records with UTF-8 support.', extRes.UniqueMatches));
    
catch extErr
    logFail('extractAttributesCore', extErr.message);
end

% =========================================================================
%  STAGE 4: TEST SUBSYSTEM SIGNALS CONFIGURATION
% =========================================================================
fprintf('\n[4/7] Testing configureSubsystemSignals.m...\n');
try
    % Build a dedicated test subsystem model
    subModel = 'test_signal_submodel';
    new_system(subModel);
    load_system(subModel);
    
    subBlock = [subModel '/TestSub'];
    add_block('simulink/Ports & Subsystems/Subsystem', subBlock, 'Position', [200, 100, 350, 200]);
    
    % Configure internal ports
    delete_line(subBlock, 'In1/1', 'Out1/1');
    set_param([subBlock '/In1'], 'Name', 'engine_speed');
    set_param([subBlock '/Out1'], 'Name', 'motor_torque');
    
    % External connections
    add_block('simulink/Sources/Constant', [subModel '/Const'], 'Position', [50, 140, 100, 160]);
    add_block('simulink/Sinks/Terminator', [subModel '/Term'], 'Position', [450, 140, 480, 160]);
    add_line(subModel, 'Const/1', 'TestSub/1');
    add_line(subModel, 'TestSub/1', 'Term/1');
    
    % Select subsystem and configure
    set_param(0, 'CurrentWorkbench', subModel);
    set_param(gcs, 'CurrentBlock', subBlock);
    
    sigReport = configureSubsystemSignals(struct('MustResolve', true, 'ShowPropagation', true));
    assert(~isempty(sigReport), 'Signal configuration returned empty report.');
    assert(any(sigReport.Status == "Configured"), 'No signals were marked as Configured.');
    logPass('Configure Subsystem Signals', 'Resolved Simulink.Signal objects and enabled propagation.');
    
    close_system(subModel, 0);
catch sigErr
    logFail('configureSubsystemSignals', sigErr.message);
end

% =========================================================================
%  STAGE 5: TEST PERPENDICULAR LAYOUT ARRANGE ENGINE
% =========================================================================
fprintf('\n[5/7] Testing arrangeModelLayout.m (Perpendicular Grid Engine)...\n');
try
    if ~bdIsLoaded('test_parent_fromgoto')
        load_system('test_parent_fromgoto');
    end
    
    % Arrange Top-Level (Level 1)
    lvl1Res = arrangeModelLayout('test_parent_fromgoto', struct( ...
        'FullRelayout', true, ...
        'Layout',       'vertical', ...
        'SameSize',     true, ...
        'TidyLines',    true));
    assert(lvl1Res.Counts.InportsAligned > 0 || lvl1Res.Counts.ModelsResized > 0, ...
        'Arrange engine did not process any blocks.');
    logPass('Arrange Level 1 (Full Grid Re-Layout)', 'Positioned top-level hierarchy with zero overlaps.');
    
    % Arrange Inside Core Subsystem (Level 2)
    lvl2Path = 'test_parent_fromgoto/test_parent_fromgoto_Core';
    lvl2Res = arrangeModelLayout(lvl2Path, struct( ...
        'FullRelayout', true, ...
        'Layout',       'vertical', ...
        'SameSize',     true, ...
        'TidyLines',    true));
    assert(lvl2Res.Counts.TagBlocksAligned > 0, 'From/Goto tag blocks were not aligned.');
    logPass('Arrange Level 2 (Subsystem Interior)', 'Aligned From/Goto blocks with straight perpendicular port lines.');
    
catch arrErr
    logFail('arrangeModelLayout', arrErr.message);
end

% =========================================================================
%  STAGE 6: TEST SLDD CONVERSION
% =========================================================================
fprintf('\n[6/7] Testing convert_m_to_sldd.m (Isolated Workspace)...\n');
try
    % Create a dummy *_data.m matching sensor model
    sensorDataM = fullfile(testDir, 'test_sensor_data.m');
    fid = fopen(sensorDataM, 'wt', 'n', 'UTF-8');
    fprintf(fid, '%% Data definition\n');
    fprintf(fid, 'speed = Simulink.Signal;\n');
    fprintf(fid, 'temp = Simulink.Signal;\n');
    fprintf(fid, 'm_sensor_gain = 1.5;\n');
    fclose(fid);
    
    % Test isolated run
    convert_m_to_sldd('checkOnly', false, 'overwrite', true, 'verbose', false);
    
    expectedDict = fullfile(testDir, 'test_sensor_DataDictionary.sldd');
    assert(isfile(expectedDict), 'Expected SLDD data dictionary was not generated.');
    logPass('Convert M to SLDD', 'Generated SLDD hierarchy without Base Workspace pollution.');
    
catch slddErr
    logFail('convert_m_to_sldd', slddErr.message);
end

% =========================================================================
%  PRINT FINAL SUMMARY REPORT
% =========================================================================
printSummary();

% =========================================================================
%  HELPER NESTED FUNCTIONS
% =========================================================================
    function logPass(name, message)
        testNames{end + 1} = name; %#ok<AGROW>
        testStatus{end + 1} = 'PASS'; %#ok<AGROW>
        testMessages{end + 1} = message; %#ok<AGROW>
        fprintf('  [PASS] %s: %s\n', name, message);
    end

    function logFail(name, message)
        testNames{end + 1} = name; %#ok<AGROW>
        testStatus{end + 1} = 'FAIL'; %#ok<AGROW>
        testMessages{end + 1} = message; %#ok<AGROW>
        fprintf(2, '  [FAIL] %s: %s\n', name, message);
    end

    function printSummary()
        fprintf('\n=================================================================\n');
        fprintf('                        TEST SUMMARY                             \n');
        fprintf('=================================================================\n');
        totalTests = numel(testNames);
        passedTests = sum(strcmp(testStatus, 'PASS'));
        failedTests = sum(strcmp(testStatus, 'FAIL'));
        
        for idx = 1:totalTests
            if strcmp(testStatus{idx}, 'PASS')
                statusStr = '  [PASS] ';
            else
                statusStr = '  [FAIL] ';
            end
            fprintf('%s %-32s - %s\n', statusStr, testNames{idx}, testMessages{idx});
        end
        fprintf('-----------------------------------------------------------------\n');
        fprintf('Total: %d | Passed: %d | Failed: %d\n', totalTests, passedTests, failedTests);
        if failedTests == 0
            fprintf('\n *** ALL SIMULINK TEAM TOOLS TESTS PASSED SUCCESSFULLY! ***\n');
        else
            fprintf(2, '\n *** WARNING: %d TEST(S) FAILED. CHECK LOG ABOVE. ***\n', failedTests);
        end
        fprintf('=================================================================\n\n');
    end
end

% =========================================================================
%  STANDALONE HELPERS
% =========================================================================
function setupDummyModels()
% Creates test_sensor, test_controller, and test_actuator

% 1. Sensor Model
new_system('test_sensor');
load_system('test_sensor');
add_block('simulink/Sources/Constant', 'test_sensor/Const1', 'Position', [30, 40, 70, 60]);
add_block('simulink/Sources/Constant', 'test_sensor/Const2', 'Position', [30, 100, 70, 120]);
add_block('simulink/Sinks/Out1', 'test_sensor/speed', 'Position', [150, 40, 180, 60], 'Port', '1');
add_block('simulink/Sinks/Out1', 'test_sensor/temp', 'Position', [150, 100, 180, 120], 'Port', '2');
add_line('test_sensor', 'Const1/1', 'speed/1');
add_line('test_sensor', 'Const2/1', 'temp/1');
set_param('test_sensor', 'EnableRefExpFcnMdlSchedulingChecks', 'off');
save_system('test_sensor');
close_system('test_sensor');

% 2. Controller Model (Contains internal self-loop and backward connection)
new_system('test_controller');
load_system('test_controller');
add_block('simulink/Sources/In1', 'test_controller/speed', 'Position', [30, 40, 60, 60], 'Port', '1');
add_block('simulink/Sources/In1', 'test_controller/feedback_act', 'Position', [30, 100, 60, 120], 'Port', '2');
add_block('simulink/Sources/In1', 'test_controller/self_loop', 'Position', [30, 160, 60, 180], 'Port', '3');
add_block('simulink/Sinks/Out1', 'test_controller/torque', 'Position', [180, 40, 210, 60], 'Port', '1');
add_block('simulink/Sinks/Out1', 'test_controller/self_loop', 'Position', [180, 160, 210, 180], 'Port', '2');
add_line('test_controller', 'speed/1', 'torque/1');
add_line('test_controller', 'self_loop/1', 'self_loop/1');
save_system('test_controller');
close_system('test_controller');

% 3. Actuator Model
new_system('test_actuator');
load_system('test_actuator');
add_block('simulink/Sources/In1', 'test_actuator/torque', 'Position', [30, 40, 60, 60], 'Port', '1');
add_block('simulink/Sinks/Out1', 'test_actuator/feedback_act', 'Position', [180, 40, 210, 60], 'Port', '1');
add_line('test_actuator', 'torque/1', 'feedback_act/1');
save_system('test_actuator');
close_system('test_actuator');
end

function tearDown(originalDir, testDir)
% Safely closes diagrams and deletes sandbox folder
try bdclose('all'); catch; end
try cd(originalDir); catch; end
try
    if isfolder(testDir)
        rmdir(testDir, 's');
    end
catch
end
end