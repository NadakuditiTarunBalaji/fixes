function convert_m_to_sldd(varargin)
%CONVERT_M_TO_SLDD Generate SLDD dictionaries safely in isolated scope.

    p = inputParser;
    p.addParameter('checkOnly', false, @(x) islogical(x) || isnumeric(x));
    p.addParameter('overwrite', true,  @(x) islogical(x) || isnumeric(x));
    p.addParameter('verbose',   true,  @(x) islogical(x) || isnumeric(x));
    p.parse(varargin{:});
    opt = p.Results;

    rootDir = pwd;
    fprintf('=== CREATION OF SLDD START ===\n');
    fprintf('Root: %s\n', rootDir);

    mfiles = dir(fullfile(rootDir, '**', '*_data.m'));
    if isempty(mfiles)
        fprintf('No "*_data.m" scripts found under: %s\n', rootDir);
        return;
    end

    for idx = 1:numel(mfiles)
        mfPath = fullfile(mfiles(idx).folder, mfiles(idx).name);
        modelName = extractModelNameFromDataScript(mfiles(idx).name);
        modelFile = fullfile(mfiles(idx).folder, [modelName '.slx']);

        fprintf('\n[%d/%d] Processing: %s\n', idx, numel(mfiles), modelName);
        if ~exist(modelFile, 'file')
            fprintf(2, '  [SKIP] Model not found: %s\n', modelFile);
            continue;
        end

        ioDictPath    = fullfile(mfiles(idx).folder, sprintf('%s_DataDictionary.sldd', modelName));
        paramDictPath = fullfile(mfiles(idx).folder, sprintf('%s_Param.sldd', modelName));
        localDictPath = fullfile(mfiles(idx).folder, sprintf('%s_Local.sldd', modelName));

        try
            % ISOLATED EXECUTION (No base workspace pollution)
            mStruct = runScriptInIsolatedScope(mfPath);
            mVars = fieldnames(mStruct);

            if ~bdIsLoaded(modelName)
                load_system(modelFile);
            end

            inports  = find_system(modelName, 'SearchDepth', 1, 'BlockType', 'Inport');
            outports = find_system(modelName, 'SearchDepth', 1, 'BlockType', 'Outport');
            inNames  = ensureCell(get_param(inports, 'Name'));
            outNames = ensureCell(get_param(outports, 'Name'));
            ioNames  = unique([inNames(:); outNames(:)]);

            isSignal = false(size(mVars));
            for i = 1:numel(mVars)
                isSignal(i) = isa(mStruct.(mVars{i}), 'Simulink.Signal');
            end

            paramNamesAll = setdiff(mVars(~isSignal), {});
            param_m_const = paramNamesAll(startsWith(paramNamesAll, 'm_'));
            param_other_def = setdiff(paramNamesAll, param_m_const);
            localSignalNames = setdiff(mVars(isSignal), ioNames);

            if opt.checkOnly
                fprintf('  [CHECK-ONLY] Preview successful for %s.\n', modelName);
                continue;
            end

            % Write IO Dictionary
            ioDict = createOrResetDict(ioDictPath, opt.overwrite);
            ioSec  = getSection(ioDict, 'Design Data');
            for i = 1:numel(ioNames)
                nm = ioNames{i};
                if isfield(mStruct, nm)
                    val = mStruct.(nm);
                    if isa(val, 'Simulink.Signal')
                        val.CoderInfo.StorageClass = 'Auto';
                        upsertEntry(ioSec, nm, val);
                    end
                end
            end
            saveChanges(ioDict);

            % Write Parameters Dictionary
            paramDict = createOrResetDict(paramDictPath, opt.overwrite);
            paramSec  = getSection(paramDict, 'Design Data');
            for i = 1:numel(param_m_const)
                nm = param_m_const{i};
                val = mStruct.(nm);
                p = Simulink.Parameter(val);
                p.CoderInfo.StorageClass = 'Custom';
                upsertEntry(paramSec, nm, p);
            end
            for i = 1:numel(param_other_def)
                nm = param_other_def{i};
                val = mStruct.(nm);
                p = Simulink.Parameter(val);
                p.CoderInfo.StorageClass = 'Custom';
                p.CoderInfo.CustomStorageClass = 'Define';
                upsertEntry(paramSec, nm, p);
            end
            saveChanges(paramDict);

            % Write Local Signals Dictionary
            localDict = createOrResetDict(localDictPath, opt.overwrite);
            localSec  = getSection(localDict, 'Design Data');
            for i = 1:numel(localSignalNames)
                nm = localSignalNames{i};
                sig = mStruct.(nm);
                sig.CoderInfo.StorageClass = 'Auto';
                upsertEntry(localSec, nm, sig);
            end
            saveChanges(localDict);

            % Link Dictionaries
            addDataSource(ioDict, sprintf('%s_Param.sldd', modelName));
            addDataSource(ioDict, sprintf('%s_Local.sldd', modelName));
            if isfile(fullfile(mfiles(idx).folder, 'ertConfig.sldd')) || isfile('ertConfig.sldd')
                addDataSource(ioDict, 'ertConfig.sldd');
            end
            saveChanges(ioDict);

            set_param(modelName, 'DataDictionary', sprintf('%s_DataDictionary.sldd', modelName));
            save_system(modelName);
            fprintf('  SLDD created and linked successfully.\n');
        catch ME
            fprintf(2, '  [ERROR] %s\n', ME.message);
        end
    end
    fprintf('=== CREATION OF SLDD END ===\n');
end

function s = runScriptInIsolatedScope(scriptPath)
    s = struct();
    run(scriptPath);
    vars = whos();
    vars = vars(~ismember({vars.name}, {'s', 'scriptPath', 'vars'}));
    for k = 1:numel(vars)
        s.(vars(k).name) = eval(vars(k).name);
    end
end

function name = extractModelNameFromDataScript(fileName)
    if endsWith(fileName, '_data.m')
        name = extractBefore(fileName, '_data.m');
    else
        [name, ~] = strtok(fileName, '.');
    end
end

function c = ensureCell(x)
    if ischar(x), c = {x}; elseif isstring(x), c = cellstr(x); else, c = x; end
end

function dictObj = createOrResetDict(dictPath, overwrite)
    if exist(dictPath, 'file')
        dictObj = Simulink.data.dictionary.open(dictPath);
        if overwrite
            sec = getSection(dictObj, 'Design Data');
            entries = find(sec, '-value');
            for k = 1:numel(entries)
                deleteEntry(sec, entries(k).Name);
            end
        end
    else
        dictObj = Simulink.data.dictionary.create(dictPath);
    end
end

function upsertEntry(secObj, name, valueObj)
    try deleteEntry(secObj, name); catch; end
    addEntry(secObj, name, valueObj);
end