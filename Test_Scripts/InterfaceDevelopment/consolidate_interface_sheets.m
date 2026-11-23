function result = consolidate_interface_sheets(inputFolder, outFile, cfg)
%CONSOLIDATE_INTERFACE_SHEETS  Merge many raw interface sheets into ONE clean sheet
%
%   consolidate_interface_sheets("demo")
%       Self-test: generates 4 messy raw sheets in tempdir, consolidates them,
%       writes BMS_Interface_Consolidated.xlsx in the current folder.
%       Run this FIRST on a new machine/release to prove the script works.
%
%   consolidate_interface_sheets("C:\BMS\raw_if_sheets")
%       Real run: reads every .xlsx/.xlsm/.xls/.csv in the folder (all sheets).
%
%   consolidate_interface_sheets(folder, outFile, cfg)
%       cfg = struct with any fields of ifcDefaults() you want to override,
%       e.g. cfg.modules = ["InProc","ContCtrl",...]; cfg.maxHeaderScan = 30;
%
%   WHAT IT DOES
%   1. Finds the header row in every sheet (title rows above it are skipped)
%      and maps columns by synonyms ("Signal Name", "Name", "Variable" ... ->
%      signal; "I/O", "Dir", "Direction" -> direction; ...).
%   2. Understands two layouts, mixed freely:
%        A) module IO list : Signal + Direction (In/Out); module taken from a
%           Module column, else from the file/sheet name. If there is no
%           Direction column, a sheet named "*Input*" / "*Output*" sets it.
%        B) system list    : Signal + Source + Destination(s).
%   3. Merges all rows per signal: producer = whoever outputs it, consumers =
%      everyone who inputs it. Picks the producer's type/unit/range.
%   4. Flags problems (see Issues sheet): 2 producers, no producer, no
%      consumer, type/unit/range conflicts, invalid names, near-duplicate
%      names (typos), unknown module names, unknown types.
%   5. Applies YOUR decisions from ifc_decisions.xlsx (created on first run
%      in the input folder):  Rename sheet (merge misspellings) and
%      Override sheet (fix a field). Raw sheets are never modified.
%
%   OUTPUT  BMS_Interface_Consolidated.xlsx
%     Consolidated : one row per signal  (columns match ifcheck config)
%     Issues       : severity, id, signal, detail, suggestion
%     RawRecords   : every row read, with file/sheet/row  (traceability)
%     Sources      : every sheet, header row found, columns mapped, skipped?
%     Summary      : counts + per-module input/output counts
%
%   Requires base MATLAB only (R2020b+; written for R2025b). No toolboxes.
%   Excel formatting (freeze panes, filters, widths) only on Windows+Excel.

arguments
    inputFolder (1,1) string = string(pwd)
    outFile     (1,1) string = "BMS_Interface_Consolidated.xlsx"
    cfg         (1,1) struct = struct()
end

cfg = finalizeCfg(mergeStruct(ifcDefaults(), cfg));

if strcmpi(inputFolder, "demo")
    inputFolder = string(fullfile(tempdir, "ifc_demo_raw"));
    makeDemo(inputFolder);
    fprintf("Demo raw sheets written to %s\n", inputFolder);
end
if ~isfolder(inputFolder)
    error("ifc:folder", "Input folder not found: %s", inputFolder);
end
[p, ~, ~] = fileparts(outFile);
if strlength(p) == 0, outFile = string(fullfile(pwd, outFile)); end
if strlength(cfg.decisionsFile) == 0
    cfg.decisionsFile = string(fullfile(inputFolder, "ifc_decisions.xlsx"));
end

%% 1. Decisions (rename / override) ---------------------------------------
ensureDecisionsTemplate(cfg.decisionsFile);
[renameOld, renameNew, ovr] = readDecisions(cfg.decisionsFile);

%% 2. Read every sheet ------------------------------------------------------
files = [dir(fullfile(inputFolder, "*.xlsx")); dir(fullfile(inputFolder, "*.xlsm"));
         dir(fullfile(inputFolder, "*.xls"));  dir(fullfile(inputFolder, "*.csv"))];
[~, outName, outExt] = fileparts(outFile);
[~, decName, decExt] = fileparts(cfg.decisionsFile);
keep = true(numel(files), 1);
for k = 1:numel(files)
    nm = string(files(k).name);
    keep(k) = ~startsWith(nm, "~$") && ~strcmpi(nm, outName + outExt) ...
              && ~strcmpi(nm, decName + decExt);
end
files = files(keep);
if isempty(files)
    error("ifc:nofiles", "No .xlsx/.xlsm/.xls/.csv files in %s", inputFolder);
end

recs = {};
srcLog = strings(0, 6);   % File, Sheet, HeaderRow, MappedColumns, RowsRead, Status
for k = 1:numel(files)
    fpath = string(fullfile(files(k).folder, files(k).name));
    [~, fbase, fext] = fileparts(fpath);
    if strcmpi(fext, ".csv")
        sheets = "(csv)";
    else
        try
            sheets = sheetnames(fpath);
        catch ME
            srcLog(end+1, :) = [files(k).name, "", "", "", "0", "SKIPPED: " + ME.message]; %#ok<AGROW>
            continue;
        end
    end
    for s = 1:numel(sheets)
        sh = sheets(s);
        if any(contains(lower(sh), lower(cfg.skipSheetsContaining)))
            srcLog(end+1, :) = [files(k).name, sh, "", "", "0", "SKIPPED: sheet name filter"]; %#ok<AGROW>
            continue;
        end
        try
            if sh == "(csv)"
                raw = readcell(fpath);
            else
                raw = readcell(fpath, "Sheet", sh);
            end
        catch ME
            srcLog(end+1, :) = [files(k).name, sh, "", "", "0", "SKIPPED: " + ME.message]; %#ok<AGROW>
            continue;
        end
        S = cellToStrings(raw);
        [hRow, map] = findHeader(S, cfg);
        if hRow == 0
            srcLog(end+1, :) = [files(k).name, sh, "", "", "0", ...
                "SKIPPED: no header row with a signal column in first " + cfg.maxHeaderScan + " rows"]; %#ok<AGROW>
            continue;
        end
        sheetModule = inferModule(fbase + " " + sh, cfg);
        if strlength(sheetModule) == 0, sheetModule = fbase; end
        sheetDir = "";
        if ~isfield(map, 'direction')
            sheetDir = dirFromSheetName(sh);
        end

        nRead = 0;
        for r = hRow+1:size(S, 1)
            sig = strtrim(S(r, map.signal));
            if strlength(sig) == 0 || any(normKey(sig) == cfg.synKeys.signal)
                continue;                               % blank or repeated header
            end
            v = @(f) fieldVal(S, r, map, f);
            rec = struct();
            rec.File      = string(files(k).name);
            rec.Sheet     = sh;
            rec.Row       = r;
            modCol        = v("module");
            if strlength(modCol) > 0
                rec.Module = canonModule(modCol, cfg);
            else
                rec.Module = sheetModule;
            end
            rec.SignalRaw = sig;
            rec.Signal    = applyRename(sig, renameOld, renameNew);
            rec.Key       = lower(rec.Signal);
            d             = normDir(v("direction"));
            if strlength(d) == 0, d = sheetDir; end
            rec.Direction = d;
            rec.Producer  = canonModule(v("producer"), cfg);
            rec.Consumers = joinS(canonList(splitList(v("consumers"), cfg), cfg));
            rec.DataTypeRaw = v("datatype");
            rec.DataType  = normType(rec.DataTypeRaw, cfg);
            rec.Unit      = v("unit");
            rec.Min       = v("min");
            rec.Max       = v("max");
            rec.Init      = v("init");
            rec.Dimension = v("dimension");
            rec.Interface = v("interface");
            rec.AutosarElement = v("element");
            rec.Description = v("description");
            recs{end+1} = rec; %#ok<AGROW>
            nRead = nRead + 1;
        end
        srcLog(end+1, :) = [files(k).name, sh, string(hRow), describeMap(map, S(hRow, :)), ...
                            string(nRead), "OK" + iff(strlength(sheetDir) > 0, " (direction from sheet name: " + sheetDir + ")", "")]; %#ok<AGROW>
    end
end
if isempty(recs)
    error("ifc:norows", "No signal rows found. Check the Sources output / header synonyms in ifcDefaults().");
end
T = struct2table([recs{:}]);

%% 3. Consolidate per signal -----------------------------------------------
[keys, ~, g] = unique(T.Key, "stable");
n = numel(keys);
col = @() strings(n, 1);
Sig = col(); Elem = col(); Prod = col(); Cons = col(); DT = col(); Unit = col();
Mn = col(); Mx = col(); Init = col(); Dim = col(); Itf = col(); Desc = col();
Srcs = col(); nProd = zeros(n, 1);
iss = strings(0, 6);       % Severity, ID, Signal, Modules, Detail, Suggestion
allMods = strings(0, 1);

for i = 1:n
    R = T(g == i, :);
    isP = R.Direction == "Out" | R.Producer ~= "";
    prods = [R.Module(R.Direction == "Out"); R.Producer(R.Producer ~= "")];
    prods = unique(prods(prods ~= ""), "stable"); prods = prods(:);
    cons = R.Module(R.Direction == "In"); cons = cons(:);
    for k = 1:height(R)
        cons = [cons; splitList(R.Consumers(k), cfg)]; %#ok<AGROW>
    end
    cons = unique(cons(cons ~= ""), "stable"); cons = cons(:);
    loop = intersect(cons, prods, "stable"); loop = loop(:);
    cons = setdiff(cons, prods, "stable"); cons = cons(:);
    allMods = [allMods; prods; cons]; %#ok<AGROW>

    if any(isP), Sig(i) = mostCommon(R.Signal(isP)); else, Sig(i) = mostCommon(R.Signal); end
    s = Sig(i);
    Prod(i) = joinS(prods); Cons(i) = joinS(cons); nProd(i) = numel(prods);
    Srcs(i) = joinS(unique(R.File + "|" + R.Sheet + "|r" + string(R.Row), "stable"));

    [DT(i),   cDT,  lDT]  = pickValue(R.DataType, isP, false);
    [Unit(i), cU,   lU]   = pickValue(R.Unit, isP, false);
    [Mn(i),   cMn,  lMn]  = pickValue(R.Min, isP, true);
    [Mx(i),   cMx,  lMx]  = pickValue(R.Max, isP, true);
    [Init(i), cIn,  lIn]  = pickValue(R.Init, isP, true);
    Dim(i)  = pickValue(R.Dimension, isP, true);
    Itf(i)  = pickValue(R.Interface, isP, false);
    Elem(i) = pickValue(R.AutosarElement, isP, false);
    Desc(i) = pickValue(R.Description, isP, false);
    if strlength(Elem(i)) == 0, Elem(i) = s; end          % default: same name

    mods = joinS([prods; cons]);
    if numel(prods) > 1
        iss(end+1, :) = ["ERROR", "CONS-01", s, Prod(i), "Produced by " + numel(prods) + " modules: " + Prod(i), ...
                         "Keep one producer (Override 'Source Module') or rename one signal"]; %#ok<AGROW>
    end
    if isempty(prods)
        iss(end+1, :) = ["ERROR", "CONS-02", s, mods, "Consumed but no module outputs it", ...
                         "Typo? see CONS-09, or add producer via Override 'Source Module'"]; %#ok<AGROW>
    end
    if isempty(cons)
        iss(end+1, :) = ["WARN", "CONS-03", s, mods, "Produced but nobody consumes it", ...
                         "Remove if internal/debug, or add consumer"]; %#ok<AGROW>
    end
    if cDT
        iss(end+1, :) = ["ERROR", "CONS-04", s, mods, "Data type conflict: " + lDT, ...
                         "Producer's type proposed (" + DT(i) + "); confirm via Override 'Data Type'"]; %#ok<AGROW>
    end
    if strlength(DT(i)) == 0
        iss(end+1, :) = ["WARN", "CONS-07", s, mods, "No data type in any source", "Add via Override 'Data Type'"]; %#ok<AGROW>
    elseif ~isKnownType(DT(i), cfg)
        iss(end+1, :) = ["INFO", "CONS-12", s, mods, "Type '" + DT(i) + "' is not builtin/enum/known", ...
                         "Add to cfg.knownTypes if it is a valid alias/bus type"]; %#ok<AGROW>
    end
    if cU
        iss(end+1, :) = ["WARN", "CONS-05", s, mods, "Unit conflict: " + lU, "Confirm via Override 'Unit'"]; %#ok<AGROW>
    end
    if cMn || cMx || cIn
        iss(end+1, :) = ["WARN", "CONS-06", s, mods, ...
            "Range/init conflict:" + iff(cMn, " Min{" + lMn + "}", "") + iff(cMx, " Max{" + lMx + "}", "") + iff(cIn, " Init{" + lIn + "}", ""), ...
            "Producer's values proposed; confirm via Override"]; %#ok<AGROW>
    end
    if ~isvarname(char(s))
        iss(end+1, :) = ["ERROR", "CONS-08", s, mods, "Not a valid identifier (spaces, leading digit, special chars or > 63 chars)", ...
                         "Rename: " + string(matlab.lang.makeValidName(char(s)))]; %#ok<AGROW>
    end
    if all(R.Direction == "" & R.Producer == "" & R.Consumers == "")
        iss(end+1, :) = ["WARN", "CONS-10", s, joinS(unique(R.Module)), "No direction, producer or consumer found in any source", ...
                         "Add a Direction column, or name sheet *Input*/*Output*"]; %#ok<AGROW>
    end
    if ~isempty(loop)
        iss(end+1, :) = ["INFO", "CONS-11", s, joinS(loop), "Module both outputs and inputs this signal", "Usually internal; check"]; %#ok<AGROW>
    end
    sp = unique(R.SignalRaw);
    if numel(sp) > 1
        iss(end+1, :) = ["INFO", "CONS-14", s, mods, "Spellings in sources: " + joinS(sp), "Unified to '" + s + "'"]; %#ok<AGROW>
    end
end

%% 4. Cross-signal checks ---------------------------------------------------
% CONS-09 near-duplicates: same name ignoring case/underscores, or an
% orphan (no producer) within edit distance of a produced signal
squash = lower(erase(Sig, ["_", " ", "-"]));
[u, ~, gg] = unique(squash);
for k = 1:numel(u)
    idx = find(gg == k);
    if numel(idx) > 1
        iss(end+1, :) = ["WARN", "CONS-09", Sig(idx(1)), "", "Same name ignoring case/underscores: " + joinS(Sig(idx)), ...
                         "If same signal: add Rename rows to ifc_decisions.xlsx"]; %#ok<AGROW>
    end
end
orph = find(nProd == 0);
prodd = find(nProd > 0);
for a = orph(:)'
    best = ""; bestD = inf;
    for b = prodd(:)'
        if strlength(Sig(a)) < cfg.fuzzyMinLength, break; end
        d = lev(lower(Sig(a)), lower(Sig(b)), cfg.fuzzyMaxDistance);
        if d < bestD, bestD = d; best = Sig(b); end
    end
    if bestD <= cfg.fuzzyMaxDistance && bestD > 0
        iss(end+1, :) = ["WARN", "CONS-09", Sig(a), Cons(a), ...
            "Has no producer but is " + bestD + " edit(s) from produced signal '" + best + "'", ...
            "Probable typo: Rename '" + Sig(a) + "' -> '" + best + "'"]; %#ok<AGROW>
    end
end
% CONS-13 unknown module names (typos in Source/Destination/Module/file name)
allMods = unique(allMods(allMods ~= ""));
for m = allMods(:)'
    if ~any(strcmpi(m, cfg.modules)) && ~any(strcmpi(m, cfg.externalModules))
        used = Sig(contains(", " + Prod + ", " + Cons + ", ", ", " + m + ", "));
        sugg = closestName(m, [cfg.modules(:); cfg.externalModules(:)]);
        iss(end+1, :) = ["WARN", "CONS-13", "(" + numel(used) + " signals)", m, ...
            "Module name not in cfg.modules / cfg.externalModules: used by " + joinS(used(1:min(5, end))) + iff(numel(used) > 5, ", ...", ""), ...
            iff(strlength(sugg) > 0, "Did you mean '" + sugg + "'? Fix source or extend cfg", "Add to cfg.modules or cfg.externalModules")]; %#ok<AGROW>
    end
end

%% 5. Build consolidated table + apply overrides ---------------------------
C = table(Sig, Elem, Prod, Cons, DT, Unit, Mn, Mx, Init, Dim, Itf, Desc, ...
    'VariableNames', ["Signal Name", "AUTOSAR Element", "Source Module", "Destination Modules", ...
                      "Data Type", "Unit", "Min", "Max", "Init", "Dimension", "Interface", "Description"]);
[C, iss] = applyOverrides(C, iss, ovr);

sev = strings(n, 1); ids = strings(n, 1);
for i = 1:n
    m = iss(:, 3) == C.("Signal Name")(i);
    ids(i) = joinS(unique(iss(m, 2)));
    if any(iss(m, 1) == "ERROR"), sev(i) = "ERROR";
    elseif any(iss(m, 1) == "WARN"), sev(i) = "CHECK";
    else, sev(i) = "OK";
    end
end
C.Status = sev; C.("Issue IDs") = ids; C.Sources = Srcs;
C = sortrows(C, ["Source Module", "Signal Name"]);

I = array2table(iss, 'VariableNames', ["Severity", "ID", "Signal", "Modules", "Detail", "Suggestion"]);
if height(I) > 0
    [~, o] = sort(arrayfun(@(x) find(x == ["ERROR", "WARN", "INFO", "RESOLVED"]), I.Severity));
    I = I(o, :);
end
Src = array2table(srcLog, 'VariableNames', ["File", "Sheet", "Header Row", "Mapped Columns", "Rows Read", "Status"]);

%% 6. Summary ---------------------------------------------------------------
cnt = @(sv) sum(I.Severity == sv);
Sm = table(["Files read"; "Sheets read"; "Sheets skipped"; "Raw rows"; "Unique signals"; ...
            "Signals OK"; "Signals CHECK"; "Signals ERROR"; "Issues ERROR"; "Issues WARN"; "Issues INFO"; "Issues RESOLVED"], ...
           [numel(files); sum(startsWith(Src.Status, "OK")); sum(startsWith(Src.Status, "SKIPPED")); height(T); n; ...
            sum(sev == "OK"); sum(sev == "CHECK"); sum(sev == "ERROR"); cnt("ERROR"); cnt("WARN"); cnt("INFO"); cnt("RESOLVED")], ...
           'VariableNames', ["Item", "Value"]);
modsAll = unique([cfg.modules(:); allMods(:)], "stable");
nOut = zeros(numel(modsAll), 1); nIn = nOut;
for k = 1:numel(modsAll)
    m = modsAll(k);
    nOut(k) = sum(contains(", " + C.("Source Module") + ", ", ", " + m + ", "));
    nIn(k)  = sum(contains(", " + C.("Destination Modules") + ", ", ", " + m + ", "));
end
Mt = table(modsAll, nOut, nIn, 'VariableNames', ["Module", "Outputs", "Inputs"]);

%% 7. Write workbook --------------------------------------------------------
if isfile(outFile), delete(outFile); end
writetable(C,  outFile, "Sheet", "Consolidated");
writetable(I,  outFile, "Sheet", "Issues");
writetable(T,  outFile, "Sheet", "RawRecords");
writetable(Src, outFile, "Sheet", "Sources");
writetable(Sm, outFile, "Sheet", "Summary", "Range", "A1");
writetable(Mt, outFile, "Sheet", "Summary", "Range", "D1");
if cfg.formatExcel && ispc
    formatWorkbook(outFile);
end

fprintf("\n=== Interface consolidation ===\n");
fprintf("Files %d | sheets read %d, skipped %d | raw rows %d -> %d signals\n", ...
    numel(files), Sm.Value(2), Sm.Value(3), height(T), n);
fprintf("Signals: OK %d | CHECK %d | ERROR %d\n", Sm.Value(6), Sm.Value(7), Sm.Value(8));
fprintf("Issues : ERROR %d | WARN %d | INFO %d | RESOLVED %d\n", Sm.Value(9), Sm.Value(10), Sm.Value(11), Sm.Value(12));
fprintf("Output : %s\nDecide : %s  (Rename / Override sheets, then re-run)\n", outFile, cfg.decisionsFile);

result = struct("Consolidated", C, "Issues", I, "RawRecords", T, "Sources", Src, "Summary", Sm, "Modules", Mt);
end

% =========================================================================
%  CONFIGURATION
% =========================================================================
function cfg = ifcDefaults()
cfg.modules = ["InProc", "ModeMgmt", "ContCtrl", "FaultMgmt", "ChrgMgmt", "ThermMgmt", ...
               "SOC", "SOP", "VoltMon", "PackCurrMon", "ModlTempMon"];
cfg.externalModules = ["BSW", "VCU", "CAN", "HW", "IoHwAb", "Calibration"];
cfg.maxHeaderScan = 25;                 % look for the header in the first N rows
cfg.skipSheetsContaining = ["revision", "history", "cover", "readme", "changelog", "legend"];
cfg.listSeparators = "[,;/|\n\r]+";     % separators in Destination lists
cfg.fuzzyMaxDistance = 2;               % edit distance for typo detection
cfg.fuzzyMinLength = 6;                 % ignore very short names for typos
cfg.decisionsFile = "";                 % default: <inputFolder>/ifc_decisions.xlsx
cfg.formatExcel = true;                 % Windows + Excel only
cfg.knownTypes = strings(1, 0);         % extra valid type names (alias/bus types)

% Column header synonyms (compared after lower-case + removing non-alphanumerics)
h.signal      = ["signal", "signalname", "name", "signalid", "variable", "variablename", ...
                 "portname", "dataname", "label", "signallabel", "identifier"];
h.direction   = ["direction", "dir", "io", "inout", "inputoutput", "porttype", "portdirection", ...
                 "portkind", "kind", "rw", "rxtx"];
h.module      = ["module", "modulename", "component", "componentname", "swc", "owner", "function", "feature"];
h.producer    = ["source", "sourcemodule", "producer", "from", "sender", "provider", "txmodule", ...
                 "sourcecomponent", "origin", "writtenby"];
h.consumers   = ["destination", "destinations", "destinationmodule", "destinationmodules", "consumer", ...
                 "consumers", "to", "receiver", "receivers", "rxmodule", "rxmodules", "readby", "usedby"];
h.datatype    = ["datatype", "type", "dtype", "basetype", "signaltype", "simulinktype"];
h.unit        = ["unit", "units", "physicalunit", "engunit", "si"];
h.min         = ["min", "minimum", "minvalue", "rangemin", "lowerlimit", "physmin", "min phys"];
h.max         = ["max", "maximum", "maxvalue", "rangemax", "upperlimit", "physmax"];
h.init        = ["init", "initvalue", "initialvalue", "default", "defaultvalue", "startvalue"];
h.dimension   = ["dimension", "dimensions", "size", "width", "arraysize"];
h.interface   = ["interface", "portinterface", "interfacename", "srinterface"];
h.element     = ["autosarelement", "dataelement", "element", "arelement", "autosarname"];
h.description = ["description", "desc", "comment", "comments", "remark", "remarks", "notes", "meaning"];
cfg.headers = h;

% Data type aliases (lower-case key -> Simulink type)
cfg.typeAliasFrom = ["float", "float32", "real32", "single", "float64", "real64", "double", ...
    "bool", "boolean", "logical", "boolean_t", "u8", "uint8", "uint8_t", "unsignedchar", ...
    "s8", "sint8", "int8", "int8_t", "u16", "uint16", "uint16_t", "s16", "sint16", "int16", "int16_t", ...
    "u32", "uint32", "uint32_t", "s32", "sint32", "int32", "int32_t", "u64", "uint64", "s64", "sint64", "int64"];
cfg.typeAliasTo = ["single", "single", "single", "single", "double", "double", "double", ...
    "boolean", "boolean", "boolean", "boolean", "uint8", "uint8", "uint8", "uint8", ...
    "int8", "int8", "int8", "int8", "uint16", "uint16", "uint16", "int16", "int16", "int16", "int16", ...
    "uint32", "uint32", "uint32", "int32", "int32", "int32", "int32", "uint64", "uint64", "int64", "int64", "int64"];
end

function cfg = mergeStruct(cfg, user)
f = fieldnames(user);
for k = 1:numel(f)
    if isstruct(user.(f{k})) && isfield(cfg, f{k}) && isstruct(cfg.(f{k}))
        cfg.(f{k}) = mergeStruct(cfg.(f{k}), user.(f{k}));
    else
        cfg.(f{k}) = user.(f{k});
    end
end
end

function cfg = finalizeCfg(cfg)
cfg.decisionsFile = string(cfg.decisionsFile);
cfg.modules = string(cfg.modules); cfg.externalModules = string(cfg.externalModules);
cfg.knownTypes = string(cfg.knownTypes);
% pre-normalise header synonyms
hf = fieldnames(cfg.headers);
cfg.synKeys = struct();
for k = 1:numel(hf)
    cfg.synKeys.(hf{k}) = normKey(cfg.headers.(hf{k}));
end
end

% =========================================================================
%  READING HELPERS
% =========================================================================
function S = cellToStrings(C)
S = strings(size(C));
for k = 1:numel(C)
    x = C{k};
    if isempty(x) || isa(x, "missing"), continue; end
    if islogical(x)
        S(k) = string(double(x));
    elseif isnumeric(x)
        if ~isscalar(x) || isnan(x), continue; end
        S(k) = string(num2str(x, "%.10g"));
    elseif isdatetime(x)
        S(k) = string(x);
    else
        S(k) = strtrim(string(x));
    end
end
end

function [hRow, map] = findHeader(S, cfg)
hRow = 0; map = struct(); best = 0;
for r = 1:min(size(S, 1), cfg.maxHeaderScan)
    m = mapHeaderRow(S(r, :), cfg);
    score = numel(fieldnames(m));
    if isfield(m, 'signal') && score >= 2 && score > best
        best = score; hRow = r; map = m;
    end
end
end

function m = mapHeaderRow(row, cfg)
m = struct();
f = fieldnames(cfg.synKeys);
for c = 1:numel(row)
    key = normKey(row(c));
    if strlength(key) == 0, continue; end
    for k = 1:numel(f)
        if ~isfield(m, f{k}) && any(key == cfg.synKeys.(f{k}))
            m.(f{k}) = c;
            break;
        end
    end
end
end

function s = describeMap(map, headerRow)
f = fieldnames(map); parts = strings(numel(f), 1);
for k = 1:numel(f)
    parts(k) = f{k} + "='" + headerRow(map.(f{k})) + "'";
end
s = joinS(parts);
end

function v = fieldVal(S, r, map, f)
f = char(f);
if isfield(map, f), v = strtrim(S(r, map.(f))); else, v = ""; end
end

function k = normKey(s)
k = lower(regexprep(string(s), "[^a-zA-Z0-9]", ""));
end

function d = normDir(s)
k = normKey(s);
if strlength(k) == 0, d = ""; return; end
if any(k == ["in", "input", "inputs", "inport", "rx", "receive", "received", "receiver", "r", ...
             "rport", "consumer", "consumed", "read", "subscribe", "required", "require"])
    d = "In";
elseif any(k == ["out", "output", "outputs", "outport", "tx", "send", "sent", "sender", "p", ...
                 "pport", "provider", "produced", "producer", "write", "publish", "provide", "provided"])
    d = "Out";
else
    d = "";
end
end

function d = dirFromSheetName(sh)
k = lower(sh);
if contains(k, ["input", "inport", "rx"]), d = "In";
elseif contains(k, ["output", "outport", "tx"]), d = "Out";
else, d = "";
end
end

function m = inferModule(txt, cfg)
m = ""; L = 0; t = lower(txt);
for k = 1:numel(cfg.modules)
    if contains(t, lower(cfg.modules(k))) && strlength(cfg.modules(k)) > L
        m = cfg.modules(k); L = strlength(m);
    end
end
end

function m = canonModule(s, cfg)
m = strtrim(string(s));
if strlength(m) == 0, return; end
names = [cfg.modules(:); cfg.externalModules(:)];
hit = find(normKey(names) == normKey(m), 1);
if ~isempty(hit), m = names(hit); end
end

function out = canonList(parts, cfg)
out = strings(numel(parts), 1);
for k = 1:numel(parts)
    out(k) = canonModule(parts(k), cfg);
end
end

function parts = splitList(s, cfg)
s = string(s);
if strlength(s) == 0, parts = strings(0, 1); return; end
parts = strtrim(string(regexp(char(s), cfg.listSeparators, "split")))';
parts = parts(parts ~= "");
end

function t = normType(s, cfg)
t = strtrim(regexprep(string(s), "^(enum|bus|valuetype)\s*:\s*", "", "ignorecase"));
if strlength(t) == 0, return; end
k = lower(regexprep(t, "\s", ""));
hit = find(cfg.typeAliasFrom == k, 1);
if ~isempty(hit), t = cfg.typeAliasTo(hit); end
end

function ok = isKnownType(t, cfg)
builtin = ["double", "single", "boolean", "int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64"];
ok = any(t == builtin) || endsWith(lower(t), "_enum") || startsWith(lower(t), "fixdt") ...
     || any(strcmpi(t, cfg.knownTypes));
end

% =========================================================================
%  MERGE HELPERS
% =========================================================================
function [val, conflict, list] = pickValue(vals, isP, numeric)
ne = vals ~= "";
val = ""; conflict = false; list = "";
if ~any(ne), return; end
if any(ne & isP), val = vals(find(ne & isP, 1)); else, val = vals(find(ne, 1)); end
u = unique(vals(ne));
if numeric
    x = str2double(u);
    if all(~isnan(x))
        conflict = numel(unique(round(x, 9))) > 1;
    else
        conflict = numel(unique(lower(u))) > 1;
    end
else
    conflict = numel(unique(lower(u))) > 1;
end
list = joinS(u);
end

function s = mostCommon(x)
[u, ~, j] = unique(x);
c = accumarray(j, 1);
[~, i] = max(c);
s = u(i);
end

function s = joinS(x)
x = string(x);
if isempty(x), s = ""; else, s = strjoin(x(:)', ", "); end
end

function out = iff(c, a, b)
if c, out = a; else, out = b; end
end

function d = lev(a, b, cap)
% Levenshtein distance with early exit when |len diff| > cap
a = char(a); b = char(b); m = numel(a); n = numel(b);
if abs(m - n) > cap, d = inf; return; end
prev = 0:n;
for i = 1:m
    cur = zeros(1, n + 1); cur(1) = i;
    for j = 1:n
        cur(j + 1) = min([prev(j + 1) + 1, cur(j) + 1, prev(j) + (a(i) ~= b(j))]);
    end
    prev = cur;
end
d = prev(end);
end

function s = closestName(m, names)
s = ""; best = inf;
for k = 1:numel(names)
    d = lev(lower(m), lower(names(k)), 3);
    if d < best, best = d; s = names(k); end
end
if best > 3, s = ""; end
end

% =========================================================================
%  DECISIONS FILE  (your manual fixes, kept separate from raw sheets)
% =========================================================================
function ensureDecisionsTemplate(f)
if isfile(f), return; end
R = table("#Example_OldName", "#Example_NewName", "#rows starting with # are ignored", ...
    'VariableNames', ["Old Name", "New Name", "Reason"]);
O = table("#Example_Signal", "Data Type", "single", "#agreed with producer owner", ...
    'VariableNames', ["Signal Name", "Field", "Value", "Reason"]);
writetable(R, f, "Sheet", "Rename");
writetable(O, f, "Sheet", "Override");
fprintf("Created decisions template: %s\n", f);
end

function [oldN, newN, O] = readDecisions(f)
oldN = strings(0, 1); newN = strings(0, 1);
O = table(strings(0, 1), strings(0, 1), strings(0, 1), 'VariableNames', ["Signal", "Field", "Value"]);
try
    R = readtable(f, "Sheet", "Rename", "TextType", "string", "VariableNamingRule", "preserve");
    if width(R) >= 2
        a = strtrim(string(R{:, 1})); b = strtrim(string(R{:, 2}));
        k = a ~= "" & b ~= "" & ~startsWith(a, "#") & ~ismissing(a) & ~ismissing(b);
        oldN = a(k); newN = b(k);
    end
catch
end
try
    X = readtable(f, "Sheet", "Override", "TextType", "string", "VariableNamingRule", "preserve");
    if width(X) >= 3
        a = strtrim(string(X{:, 1})); b = strtrim(string(X{:, 2})); c = strtrim(string(X{:, 3}));
        c(ismissing(c)) = "";
        k = ~ismissing(a) & ~ismissing(b) & a ~= "" & ~startsWith(a, "#");
        O = table(a(k), b(k), c(k), 'VariableNames', ["Signal", "Field", "Value"]);
    end
catch
end
end

function s = applyRename(s, oldN, newN)
hit = find(strcmpi(oldN, s), 1);
if ~isempty(hit), s = newN(hit); end
end

function [C, iss] = applyOverrides(C, iss, O)
fieldIssues = struct("datatype", ["CONS-04", "CONS-07", "CONS-12"], "unit", "CONS-05", ...
    "min", "CONS-06", "max", "CONS-06", "init", "CONS-06", ...
    "sourcemodule", ["CONS-01", "CONS-02"], "destinationmodules", "CONS-03");
vn = string(C.Properties.VariableNames);
for k = 1:height(O)
    r = find(strcmpi(C.("Signal Name"), O.Signal(k)), 1);
    c = find(normKey(vn) == normKey(O.Field(k)), 1);
    if isempty(r) || isempty(c)
        iss(end+1, :) = ["WARN", "DEC-01", O.Signal(k), "", ...
            "Override not applied: " + iff(isempty(r), "signal not found", "field '" + O.Field(k) + "' not a column"), ...
            "Check spelling in ifc_decisions.xlsx"]; %#ok<AGROW>
        continue;
    end
    C{r, c} = O.Value(k);
    fk = char(normKey(O.Field(k)));
    if isfield(fieldIssues, fk)
        m = iss(:, 3) == C.("Signal Name")(r) & ismember(iss(:, 2), fieldIssues.(fk));
        iss(m, 1) = "RESOLVED";
        iss(m, 5) = iss(m, 5) + "  [override: " + vn(c) + " = " + O.Value(k) + "]";
    end
end
end

% =========================================================================
%  EXCEL FORMATTING (Windows + Excel only; silently skipped otherwise)
% =========================================================================
function formatWorkbook(f)
xl = [];
try
    xl = actxserver("Excel.Application");
    xl.DisplayAlerts = false;
    wb = xl.Workbooks.Open(char(f));
    for i = 1:wb.Sheets.Count
        ws = wb.Sheets.Item(i);
        ws.Activate;
        win = xl.ActiveWindow;
        win.FreezePanes = false;
        win.SplitColumn = 0;
        win.SplitRow = 1;
        win.FreezePanes = true;
        hdr = ws.Rows.Item(1); fnt = hdr.Font; fnt.Bold = true;
        ur = ws.UsedRange; urc = ur.Columns; urc.AutoFit;
        for c = 1:urc.Count
            colObj = ws.Columns.Item(c);
            if colObj.ColumnWidth > 60, colObj.ColumnWidth = 60; end
        end
        if ~strcmp(char(ws.Name), 'Summary')
            ur.AutoFilter;
        end
    end
    wb.Sheets.Item(1).Activate;
    wb.Save; wb.Close(false); xl.Quit; delete(xl);
catch ME
    warning("ifc:format", "Excel formatting skipped: %s", ME.message);
    if ~isempty(xl), try, xl.Quit; delete(xl); catch, end, end
end
end

% =========================================================================
%  DEMO DATA  (4 messy raw sheets with known defects)
% =========================================================================
function wc(C, varargin)
% writecell with string scalars converted to char (safest across releases)
for k = 1:numel(C)
    if isstring(C{k}), C{k} = char(C{k}); end
end
writecell(C, varargin{:});
end

function makeDemo(folder)
if isfolder(folder), rmdir(folder, "s"); end
mkdir(folder);

% A) ContCtrl IO list: title rows above header, I/O column, own type names
ContCtrl = {
    "ContCtrl - Interface List", [], [], [], [], [], [];
    "Rev 3 / owner: dev A",      [], [], [], [], [], [];
    [], [], [], [], [], [], [];
    "Signal Name", "I/O", "Data Type", "Unit", "Min", "Max", "Description";
    "Bms_PackVolt_V",      "In",  "single",           "V",  0,     1000, "Pack voltage";
    "Bms_PackCurr_A",      "In",  "float32",          "A",  -1000, 1000, "Pack current";
    "ModeMngt_St_Enum",    "In",  "ModeMgmt_St_Enum", "",   [],    [],   "BMS mode";
    "Bms_PosContFb_Sts",   "In",  "bool",             "",   [],    [],   "Pos contactor feedback";
    "ContCtrl_PosContCmd", "Out", "boolean",          "",   [],    [],   "Pos contactor command";
    "ContCtrl_St_Enum",    "Out", "ContCtrl_St_Enum", "",   [],    [],   "Contactor state";
    "ContCtrl_Dbg_Timer",  "Out", "uint16",           "ms", 0,     65535, "Debug timer"};
wc(ContCtrl, fullfile(folder, "ContCtrl_IO_v3.xlsx"), "Sheet", "IO_List");
wc({"Rev", "Date", "Change"; 1, "2026-01-10", "initial"}, ...
          fullfile(folder, "ContCtrl_IO_v3.xlsx"), "Sheet", "Revision History");

% B) VoltMon: no direction column, Inputs/Outputs sheets, other header names
wc({"Name", "Type", "Units", "Range Min", "Range Max";
           "Bms_PackVolt_V",        "float", "V", 0, 900;          % range conflict
           "VoltMon_CellVoltMax_V", "single", "V", 0, 5}, ...
          fullfile(folder, "VoltMon_Interface.xlsx"), "Sheet", "Outputs");
wc({"Name", "Type", "Units";
           "Bms_PackCur_A", "single", "A"}, ...                  % typo of Bms_PackCurr_A
          fullfile(folder, "VoltMon_Interface.xlsx"), "Sheet", "Inputs");

% C) PackCurrMon as CSV, type conflict with ContCtrl (double vs float32)
wc({"Signal", "Dir", "DataType", "Unit";
           "Bms_PackCurr_A", "Out", "double", "A"}, fullfile(folder, "PackCurrMon.csv"));

% D) System overview: Source / Destination layout
wc({"Signal", "Source", "Destination", "Data Type";
           "ModeMngt_St_Enum",  "ModeMgmt",    "ContCtrl; ChrgMgmt", "Enum: ModeMgmt_St_Enum";
           "Bms_PosContFb_Sts", "InProc",      "ContCtrl",           "boolean";
           "SOC_Pack_pct",      "SOC",         "ChrgMgmt, VCU",      "single";
           "SOC_Pack_pct",      "SOP",         "VCU",                "single";     % 2 producers
           "Bms PackTemp",      "ModlTempMon", "ThermMgmt",          "single";     % invalid name
           "ChrgMgmt_CurrReq_A","ChrgMgt",     "VCU",                "single";     % module typo
           "VoltMon_CellVoltMax_V", "VoltMon", "FaultMgmt/SOC",      "single"}, ...
          fullfile(folder, "System_Signals_Overview.xlsx"), "Sheet", "Signals");
% Expected on the demo (no decisions yet):
%   CONS-01 SOC_Pack_pct (SOC+SOP) | CONS-02 Bms_PackCur_A | CONS-09 Bms_PackCur_A ~ Bms_PackCurr_A
%   CONS-04 Bms_PackCurr_A (single vs double) | CONS-06 Bms_PackVolt_V Max{1000,900}
%   CONS-08 'Bms PackTemp' | CONS-13 'ChrgMgt' (did you mean ChrgMgmt)
%   CONS-03 ContCtrl_Dbg_Timer, ContCtrl_PosContCmd, ContCtrl_St_Enum (no consumer in demo)
%   "Revision History" sheet skipped
end
