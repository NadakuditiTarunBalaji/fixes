function convert_m_to_sldd(varargin)
    % GENERATE_SLDD_FOR_SUBTREE
    % Recursively finds M-file scripts named "*_data.m" under the current folder,
    % and for each, creates three SLDDs in the SAME folder as the M-file:
    %   1) <modelName>_DataDictionary.sldd   : Inport/Outport (Simulink.Signal, StorageClass='Auto')
    %   2) <modelName>_Param.sldd            : Parameters from M-file (m_* -> Const; others -> Define)
    %   3) <modelName>_Local.sldd            : Simulink.Signal from M-file (Auto), excluding IO names
    %
    % STRICT PRECHECK:
    %   - Runs the M-file in BASE workspace (no parsing).
    %   - Checks which of the M-file variables are referenced by the model.
    %   - Any unresolved variables are listed in MATLAB Command Window; SLDD creation is SKIPPED.
    %
    % Options (Name-Value):
    %   'checkOnly' (logical) : default true  -> preview only, do NOT write SLDDs
    %   'overwrite' (logical) : default true  -> clear existing SLDD contents if they exist
    %   'verbose'   (logical) : default true  -> additional logging
    %
    % Usage:
    %   % Dry run (preview only):
    %   generate_sldd_for_subtree('checkOnly', true);
    %
    %   % Create dictionaries (after preview is clean):
    %   generate_sldd_for_subtree('checkOnly', false, 'overwrite', true);
    
    % ---------------- Options ----------------
    p = inputParser;
    p.addParameter('checkOnly', true,  @(x)islogical(x) || isnumeric(x));
    p.addParameter('overwrite', true,  @(x)islogical(x) || isnumeric(x));
    p.addParameter('verbose',   true,  @(x)islogical(x) || isnumeric(x));
    p.addParameter('rootDir',   pwd,    @(x)ischar(x) || isstring(x));
    p.addParameter('modelName', '',     @(x)ischar(x) || isstring(x));
    p.addParameter('runUnusedAudit', false, @(x)islogical(x) || isnumeric(x));
    p.addParameter('ProgressFcn', [], @(x)isempty(x) || isa(x, 'function_handle'));
    p.parse(varargin{:});
    opt = p.Results;
    
    rootDir = char(opt.rootDir);
    reportProgress(opt, 0, 'Starting SLDD workflow.');
    fprintf('=== CREATION OF SLDD START ===\n');
    fprintf('Root     : %s\n', rootDir);
    % fprintf('CheckOnly: %d | Overwrite: %d | Verbose: %d\n', logical(opt.checkOnly), logical(opt.overwrite), logical(opt.verbose));
    
    % ---------------- Find *_data.m scripts recursively ----------------
    if ~isempty(opt.modelName)
        targetModel = char(opt.modelName);
        mfiles = dir(fullfile(rootDir, '**', [targetModel '_data.m']));
        if isempty(mfiles)
            directMatch = fullfile(rootDir, [targetModel '_data.m']);
            if exist(directMatch, 'file')
                mfiles = dir(directMatch);
            end
        end
    else
        mfiles = dir(fullfile(rootDir, '**', '*_data.m'));
    end
    if isempty(mfiles)
        fprintf(2, 'No "*_data.m" scripts found under: %s\n', rootDir);
        fprintf('=== END (nothing to do) ===\n');
        return;
    end
    
    %     fprintf('Found %d M-file(s):\n', numel(mfiles));
    %     for k = 1:numel(mfiles)
    %         fprintf('  - %s\n', fullfile(mfiles(k).folder, mfiles(k).name));
    %     end
    Simulink.data.dictionary.closeAll
    
    % ---------------- Process each script ----------------
    for idx = 1:numel(mfiles)
        mfPath = fullfile(mfiles(idx).folder, mfiles(idx).name);
        modelName = extractModelNameFromDataScript(mfiles(idx).name); % strip "_data.m"
        modelFile = fullfile(mfiles(idx).folder, [modelName '.slx']);
    
        fprintf('\n--- [%d/%d] Processing model: %s ---\n', idx, numel(mfiles), modelName);
        fprintf('Folder   : %s\n', mfiles(idx).folder);
        fprintf('M-File   : %s\n', mfiles(idx).name);
        reportProgress(opt, (idx - 1) / numel(mfiles), ...
            sprintf('Processing model %s.', modelName));
    
        if ~exist(modelFile, 'file')
            fprintf(2, '  [SKIP] Model file not found in this folder: %s\n', modelFile);
            fprintf(2, '         Expected pattern: <modelName>.slx alongside <modelName>_data.m\n');
            continue;
        end
    
        % Prepare output paths (same folder as M-file)
        ioDictPath    = fullfile(mfiles(idx).folder, sprintf('%s_DataDictionary.sldd', modelName));
        paramDictPath = fullfile(mfiles(idx).folder, sprintf('%s_Param.sldd',          modelName));
        localDictPath = fullfile(mfiles(idx).folder, sprintf('%s_Local.sldd',          modelName));
    
        % Change into the folder so 'load_system' can find the model locally
        oldDir = pwd;
        cleanupCwd = onCleanup(@() cd(oldDir));
        cd(mfiles(idx).folder);
    
        try
            % ==== Stage 1: Run M-file in BASE and capture MVars ====
            pre = evalin('base', 'whos');
            reportProgress(opt, 0.10, 'Running data script in the base workspace.');
            try
                evalin('base', sprintf('run(''%s'');', mfPath));
            catch ME
                fprintf(2, '  Error running M-file: %s\n', ME.message);
                % Do not proceed with this model
                clearMVarsFromBase(pre);
                continue;
            end
            post = evalin('base', 'whos');
            mVars = setdiff({post.name}, {pre.name});
            mVars = setdiff(mVars, {'ans'}); % minor filter
    
            % ==== Stage 2: Resolution check ====
            reportProgress(opt, 0.25, 'Checking model signal resolution.');
    
            % Ensure model is loaded
            if ~bdIsLoaded(modelName)
                load_system(modelName);
            end
            
            % Get a valid handle
            try
                mdlH = get_param(modelName, 'Handle');
            catch
                mdlH = load_system(modelName);
            end
    
            % 2. Find all signal lines in the model
            % This returns a cell array of handles to the signal lines
            signalLines = find_system(modelName, 'FindAll', 'on', 'Type', 'line');
            
            % Initialize an empty cell array to store resolved signal names
            varsInfo = {};
            
            % 3. Iterate through each signal line to check its properties
            for i = 1:length(signalLines)
                currentLine = signalLines(i);
                % Get the source port handle
                srcPortHandle = get_param(currentLine, 'SrcPortHandle');
            
                % Check if the source port handle is valid
                if srcPortHandle ~= -1
                    % Check the 'MustResolveToSignalObject' property of the source port
                    mustResolve = get_param(srcPortHandle, 'MustResolveToSignalObject');
                    
                    if strcmp(mustResolve, 'on')
                        % Get the signal name
                        signalName = get_param(currentLine, 'Name');
                        % If it has a name and is set to resolve, add it to the list
                        if ~isempty(signalName)
                            varsInfo{end+1,1} = signalName;
                        end
                    end
                end
            end
            
            usedNames = unique(varsInfo);
            cand = intersect(mVars, usedNames);
    
            if opt.verbose
                % fprintf('  Variables present in M-file : %d | Resolved in model: %d\n', numel(mVars), numel(cand));
            end
    
            unresolved = {};
            for i = 1:numel(cand)
                nm = cand{i};
                try
                    slResolve(nm, modelName); % success if no error
                catch
                    unresolved{end+1} = nm; %#ok<AGROW>
                end
            end
    
            if ~isempty(unresolved)
                fprintf(2, '  UNRESOLVED variables (from M-file & used by model): %d\n', numel(unresolved));
                for u = 1:numel(unresolved)
                    fprintf(2, '    - %s\n', unresolved{u});
                end
                fprintf(2, '  [SKIP] Resolve the above and re-run. No SLDDs were written for %s.\n', modelName);
                clearMVarsFromBase(pre);
                continue;
            else
                % fprintf('  All relevant M-file variables resolve in the model. ✅\n');
            end
    
            % ==== Stage 3: Classification ====
            reportProgress(opt, 0.45, 'Classifying I/O, parameters, and local signals.');
            % IO names
            inports  = find_system(modelName, 'SearchDepth', 1, 'BlockType','Inport');
            outports = find_system(modelName, 'SearchDepth', 1, 'BlockType','Outport');
            inNames  = ensureCell(get_param(inports,  'Name'));
            outNames = ensureCell(get_param(outports, 'Name'));
            ioNames  = unique([inNames(:); outNames(:)]);
    
            % Identify types for MVars
            isSignal = false(size(mVars));
            for i = 1:numel(mVars)
                nm = mVars{i};
                try
                    val = evalin('base', nm);
                    isSignal(i) = isa(val, 'Simulink.Signal');
                catch
                    isSignal(i) = false;
                end
            end
    
            % Parameters (exclude Simulink.Signal)
            paramNamesAll = setdiff(mVars(~isSignal), {});
            param_m_const   = paramNamesAll(startsWith(paramNamesAll, 'm_'));
            param_other_def = setdiff(paramNamesAll, param_m_const);
    
            % Local Signals (Simulink.Signal) excluding IO names
            localSignalNames = setdiff(mVars(isSignal), ioNames);
    
            %             fprintf('  Plan:\n');
            %             fprintf('    IO (In/Out, Signal Auto): %d\n', numel(ioNames));
            %             fprintf('    Params m_*  -> Const    : %d\n', numel(param_m_const));
            %             fprintf('    Params other-> Define   : %d\n', numel(param_other_def));
            %             fprintf('    Local Signals (Auto)    : %d\n', numel(localSignalNames));
    
            if opt.checkOnly
                reportProgress(opt, 1.0, 'Preview complete. No files were written.');
                fprintf('  [CHECK-ONLY] No files will be written.\n');
                fprintf('  Targets:\n    %s\n    %s\n    %s\n', ioDictPath, paramDictPath, localDictPath);
                % Clean base workspace pollution from this M-file
                clearMVarsFromBase(pre);
                continue;
            end
    
            % ==== Stage 4: Create dictionaries ====
            reportProgress(opt, 0.55, 'Creating data dictionaries.');
            % 4.1 IO dictionary (Inport/Outport -> Simulink.Signal, Auto)
            ioDict = createOrResetDict(ioDictPath, opt.overwrite);
            ioSec  = getSection(ioDict, 'Design Data');
            for i = 1:numel(ioNames)
                nm = ioNames{i};
                try
                    val = evalin('base', nm);
                    val.CoderInfo.StorageClass = 'Auto';
                    upsertEntry(ioSec, nm,val);
                catch ME
                    warning('  IO: Failed to add "%s": %s', nm, ME.message);
                end
            end
            saveChanges(ioDict);
    
            % 4.2 Parameters dictionary (m_* -> Const; others -> Define)
            paramDict = createOrResetDict(paramDictPath, opt.overwrite);
            paramSec  = getSection(paramDict, 'Design Data');
            % m_* -> Const
            for i = 1:numel(param_m_const)
                nm = param_m_const{i};
                try
                    val = evalin('base', nm);
                    if isa(val, 'Simulink.Parameter')
                        p = val;
                    else
                        p = Simulink.Parameter(val);
                    end
                    p.CoderInfo.StorageClass = 'Custom';
                    upsertEntry(paramSec, nm, p);
                catch ME
                    warning('  Param(Const): Failed to add "%s": %s', nm, ME.message);
                end
            end
            % others -> Define
            for i = 1:numel(param_other_def)
                nm = param_other_def{i};
                try
                    val = evalin('base', nm);
                    if isa(val, 'Simulink.Parameter')
                        p = val;
                    elseif ~isnumeric(val)
                        p = Simulink.Parameter(val);
                    else
                        p            = Simulink.Parameter;
                        p.Value      = val;
                        p.Dimensions = [1 1];
                    end                
                    p.CoderInfo.StorageClass = 'Custom';
                    p.CoderInfo.CustomStorageClass = 'Define';                
                    upsertEntry(paramSec, nm, p);
                catch ME
                    warning('  Param(Define): Failed to add "%s": %s', nm, ME.message);
                end
            end
            saveChanges(paramDict);
    
            % 4.3 Local Signals dictionary (Simulink.Signal, Auto)
            localDict = createOrResetDict(localDictPath, opt.overwrite);
            localSec  = getSection(localDict, 'Design Data');
            for i = 1:numel(localSignalNames)
                nm = localSignalNames{i};
                try
                    val = evalin('base', nm);
                    if isa(val, 'Simulink.Signal')
                        sig = val; % preserve existing object
                    else
                        sig = Simulink.Signal;
                    end
                    sig.CoderInfo.StorageClass = 'Auto';
                    upsertEntry(localSec, nm, sig);
                catch ME
                    warning('  Local(Signal Auto): Failed to add "%s": %s', nm, ME.message);
                end
            end
            saveChanges(localDict);
    
            % Referencing DataDictionary
            reportProgress(opt, 0.80, 'Linking parameter and local dictionaries.');
            addDataSource(ioDict, sprintf('%s_Param.sldd', modelName));
            addDataSource(ioDict, sprintf('%s_Local.sldd', modelName));
            addDataSource(ioDict, sprintf('ertConfig.sldd'));
            saveChanges(ioDict);
    
            % Adding Data Dictioanry to Model
            set_param(modelName, 'DataDictionary', sprintf('%s_DataDictionary.sldd', modelName));
            configRef = Simulink.ConfigSetRef;
            set_param(configRef, 'SourceName', 'ertConfig')
            set_param(configRef, 'Name', 'ertConfig')
            try                 
                attachConfigSet(modelName, configRef)
            catch
            end            
            setActiveConfigSet(modelName, 'ertConfig')
            save_system(modelName);
            reportProgress(opt, 0.95, 'Attaching dictionaries and saving the model.');
            
    
            fprintf('  SLDD Created:\n');
            fprintf('    %s\n    %s\n    %s\n', ioDictPath, paramDictPath, localDictPath);
    
        catch ME
            fprintf(2, '  [ERROR] %s\n', ME.message);
        end
    
        % ==== Stage 5: Cleanup base workspace ====
        clearMVarsFromBase(pre);

        % if opt.runUnusedAudit
        %     unusedVars = Simulink.findVars(modelName, 'FindUsedVars', 'off', 'SourceType', 'data dictionary');

        %     if ~isempty(unusedVars)
        %         for varIdx=1:length(unusedVars)
        %             if ~strcmp(unusedVars(varIdx,1).Name,'ertConfig')
        %                 fprintf(2,'    Unused Variable "%s" present in "%s" \n', unusedVars(varIdx,1).Name, unusedVars(varIdx,1).Source);
        %             end
        %         end
        %     end
        % end
        if opt.runUnusedAudit
            unusedVars = Simulink.findVars(modelName, 'FindUsedVars', 'off', 'SourceType', 'data dictionary')

            if ~isempty(unusedVars)

                % Create output file dynamically using modelName
                outputFile = sprintf('%s_unused_labels.txt', modelName);

                % Open file for writing
                fileID = fopen(outputFile, 'w');

                if fileID == -1
                    error('Could not create file: %s', outputFile);
                end

                % Make sure the file is closed even if an error occurs
                cleanupObj = onCleanup(@() fclose(fileID));

                for varIdx = 1:length(unusedVars)

                    if ~strcmp(unusedVars(varIdx,1).Name, 'ertConfig')

                        % Same message on Command Window
                        fprintf(2, '    Unused Variable "%s" present in "%s" \n', ...
                            unusedVars(varIdx,1).Name, ...
                            unusedVars(varIdx,1).Source);

                        % Write the same message to the text file
                        fprintf(fileID, ...
                            '    Unused Variable "%s" present in "%s"\n', ...
                            unusedVars(varIdx,1).Name, ...
                            unusedVars(varIdx,1).Source);
                    end
                end
            end
        end



        reportProgress(opt, idx / numel(mfiles), sprintf('Completed model %s.', modelName));
    end
        
    fprintf('\n=== CREATION OF SLDD END ===\n');
    reportProgress(opt, 1.0, 'SLDD workflow complete.');
end
    
% ========= Helpers =========
function name = extractModelNameFromDataScript(fileName)
    % Expect "<model>_data.m"
    if endsWith(fileName, '_data.m')
        name = extractBefore(fileName, '_data.m');
    else
        % fallback: strip extension
        [name, ~] = strtok(fileName, '.');
    end
end

function c = ensureCell(x)
    if ischar(x)
        c = {x};
    elseif isstring(x)
        c = cellstr(x);
    else
        c = x;
    end
end

function dictObj = createOrResetDict(dictPath, overwrite)
    if exist(dictPath, 'file')
        dictObj = Simulink.data.dictionary.open(dictPath);
        if overwrite
            sec = getSection(dictObj, 'Design Data');
            entries = find(sec, '-value'); % all entries
            for k = 1:numel(entries)
                deleteEntry(sec, entries(k).Name);
            end
        end
    else
        dictObj = Simulink.data.dictionary.create(dictPath);
    end
end

function upsertEntry(secObj, name, valueObj)
    % Replace if exists, else add new
    try
        getEntry(secObj, name); % exists
        deleteEntry(secObj, name);
    catch
        % not exist
    end
    addEntry(secObj, name, valueObj);
end

function reportProgress(opt, fraction, message)
if isfield(opt, 'ProgressFcn') && ~isempty(opt.ProgressFcn)
    try
        opt.ProgressFcn(fraction, message);
    catch
    end
end
end

function clearMVarsFromBase(preWhos)
    % Clear only variables that were introduced since 'preWhos'
    try
        post = evalin('base', 'whos');
        newNames = setdiff({post.name}, {preWhos.name});
        if ~isempty(newNames)
            % Build a clear command with proper quoting for each var
            parts = strcat('''', newNames, '''');
            cmd = sprintf('clear(%s);', strjoin(parts, ','));
            evalin('base', cmd);
        end
    catch
        % ignore
    end
end