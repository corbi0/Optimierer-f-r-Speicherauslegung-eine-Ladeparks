function result = optimize_battery_grid_ES_mu_lambda_preisfunktion(modelName, t_seconds, load_kW, opts)
% (μ,λ)-Evolutionsstrategie mit Komma/Plus-Selektion, Elite, Big-Jumps (nur infeasible)
% und Multi-Cluster-Restarts. Bewertung der Cover-Quote exakt auf Profilraster.
%
% Pflicht: Simulink schreibt To-Workspace 'Unserved_ws' (Structure With Time, timeseries, Dataset).
%
% Ergebnisfelder:
%   result.best_E_nom_kWh, result.best_P_grid_max_kW, result.best_cost,
%   result.best_cover, result.feasible, result.history (Tabelle), result.parents (Tabelle)

%% ---------- Konfiguration laden ----------
cfg.c_batt          = getf(opts,'c_batt',80);
cfg.c_grid          = getf(opts,'c_grid',200);
cfg.targetCoverFrac = getf(opts,'targetCoverFrac',0.95);
cfg.minServeRatio   = getf(opts,'minServeRatio',0.90);

cfg.mu              = getf(opts,'mu',3);
cfg.lambda          = getf(opts,'lambda',12);

cfg.mode            = getf(opts,'mode','selfadapt');   % 'selfadapt' | 'abs'
cfg.sigma0          = getf(opts,'sigma0',[0.2 0.2]);   % rel. Start-Sigma
cfg.sigmaMinRel     = getf(opts,'sigmaMinRel',0.01);
cfg.sigmaMaxRel     = getf(opts,'sigmaMaxRel',0.8);

cfg.stepE_kWh       = getf(opts,'stepE_kWh',[10 40]);  % für mode='abs'
cfg.stepP_kW        = getf(opts,'stepP_kW',[5 20]);

cfg.E_bounds        = getf(opts,'E_bounds',[1 Inf]);
cfg.P_bounds        = getf(opts,'P_bounds',[1 Inf]);

cfg.maxGen          = getf(opts,'maxGen',200);
cfg.verbose         = getf(opts,'verbose',true);
cfg.rngSeed         = getf(opts,'rngSeed',[]);
cfg.costTol         = getf(opts,'costTol',1e-2);
cfg.coverTol        = getf(opts,'coverTol',1e-4);

% --- Deine gewünschte, schlanke Steuerung ---
cfg.sigmaMul        = getf(opts,'sigmaMul',1.0);      % globaler Faktor auf JEDE Mutation
cfg.clusterRadiusRel= getf(opts,'clusterRadiusRel',0.20); % Restart: Verteilung der Cluster-Zentren (±%)
cfg.clusterSigmaMul = getf(opts,'clusterSigmaMul',1.0);   % NUR 1. Gen nach Restart: Kinder zusätzlich aufblasen

% Big-Jumps NUR infeasible
cfg.bigJumpProb     = getf(opts,'bigJumpProb',0.4);
cfg.bigJumpFactor   = getf(opts,'bigJumpFactor',10.0);

% Anti-Stuck / Selektion
cfg.keepBestCoverElite        = getf(opts,'keepBestCoverElite',true);
cfg.useMuPlusLambdaWhenInfeas = getf(opts,'useMuPlusLambdaWhenInfeasible',true);

% Einheitlicher Stall-Zähler (feasible + infeasible)
cfg.stallGen                  = getf(opts,'stallGen',25);
cfg.restartOnStall            = getf(opts,'restartOnStall',true);
cfg.maxRestarts               = getf(opts,'maxRestarts',3);
cfg.restart_center_noise      = getf(opts,'restart_center_noise',0.05);

% Multi-Cluster
cfg.clusterCount              = getf(opts,'numRestartClusters',4);

cfg.coverPriorityEps          = getf(opts,'coverPriorityEps',1e-3);

E0_kWh = getf(opts,'E0_kWh',[]);

E0 = getf(opts,'E_nom_kWh0',NaN);
P0 = getf(opts,'P_grid_max_kW0',NaN);
assert(isfinite(E0) && isfinite(P0),'Bitte Startwerte E_nom_kWh0 und P_grid_max_kW0 angeben.');
x0 = [E0 P0];

if ~isempty(cfg.rngSeed), rng(cfg.rngSeed); end
% ---- Optionen in cfg überführen (opts -> cfg) ----
if ~exist('opts','var') || isempty(opts), opts = struct; end
if ~exist('cfg','var')  || isempty(cfg),  cfg  = struct; end
fn = fieldnames(opts);
for k = 1:numel(fn)
    cfg.(fn{k}) = opts.(fn{k});
end


%% ---------- Simulink vorbereiten ----------
if ~bdIsLoaded(modelName), open_system(modelName); % nach open_system(modelName)
set_param(modelName,'FastRestart','on');     % Rebuild nur 1×
set_param(modelName,'SimulationCommand','update'); end % genau 1× vor Start
mdlW = get_param(modelName,'ModelWorkspace');

Load_ts = timeseries(load_kW(:), t_seconds(:));
assignin('base','Load_ts',Load_ts);
try, set_param(modelName,'StopTime',num2str(t_seconds(end))); end

%% ---------- Eltern initialisieren ----------
parents = repmat(struct('E',E0,'P',P0,'sigma',[NaN NaN], ...
                        'cost',NaN,'cover',NaN,'feasible',false), cfg.mu,1);

if strcmpi(cfg.mode,'selfadapt')
    sigma_abs = max([1 1], abs(x0).*cfg.sigma0(:)'); % absolute Start-Sigmas
else
    sigma_abs = [mean(cfg.stepE_kWh) mean(cfg.stepP_kW)];
end
for i=1:cfg.mu, parents(i).sigma = sigma_abs; end

% Eltern bewerten
for i=1:cfg.mu
    parents(i) = evalCandidate(parents(i).E, parents(i).P, parents(i).sigma);
end

% bester bisher
bestPar = best_of(parents);

% ---- Laufvariablen initialisieren (einmalig!) ----
noImproveCounter  = 0;
stallCoverCounter = 0;
restartCount      = 0;

pcov = [parents.cover];
pcov = pcov(~isnan(pcov));
if isempty(pcov)
    bestCoverSoFar = 0;
else
    bestCoverSoFar = max(pcov);
end
% ---------------------------------------------------


% History: [Gen, E_center, P_center, best_cost, best_cover, feasible, accBest, meanSigmaE, meanSigmaP]
hist = nan(cfg.maxGen, 9);

% Flag: NUR die erste Kinder-Generation nach einem Restart stärker aufblasen
applyClusterSigmaThisGen = false;

%% ---------- Hauptschleife ----------
for gen = 1:cfg.maxGen
    % Zentrum = Mittel der Eltern
    E_center = mean([parents.E]);
    P_center = mean([parents.P]);
    sigma_center = mean(cat(1,parents.sigma),1);

    % λ Kinder erzeugen
    kids(cfg.lambda,1) = struct('E',[],'P',[],'sigma',[],'cost',[],'cover',[],'feasible',[]);
    for j=1:cfg.lambda
        switch lower(cfg.mode)
            case 'selfadapt'
                tau0 = 1/sqrt(2*2);
                tau  = 1/sqrt(2*sqrt(2));
                sig_child = sigma_center .* exp(tau0*randn + tau*randn(1,2));
                sig_child = max(sig_child, abs([E_center P_center]).*cfg.sigmaMinRel);
                sig_child = min(sig_child, abs([E_center P_center]).*cfg.sigmaMaxRel);
                step      = (cfg.sigmaMul .* sig_child) .* randn(1,2);
            otherwise
                stepVec = [ ...
                    unif(cfg.stepE_kWh(1), cfg.stepE_kWh(2)) * sign(randn), ...
                    unif(cfg.stepP_kW(1),  cfg.stepP_kW(2))  * sign(randn)];
                step      = cfg.sigmaMul .* stepVec;
                sig_child = abs(stepVec);
        end

        % Big-Jump nur solange infeasible
        if ~bestPar.feasible && (rand < cfg.bigJumpProb)
            step = cfg.bigJumpFactor .* step;
        end

        % Einmalig: nach Restart Kinder zusätzlich aufblasen
        if applyClusterSigmaThisGen
            step = cfg.clusterSigmaMul .* step;
        end

        x_try = [E_center P_center] + step;

        % Box-Grenzen
        x_try(1) = clamp(x_try(1), cfg.E_bounds);
        x_try(2) = clamp(x_try(2), cfg.P_bounds);

        kids(j) = evalCandidate(x_try(1), x_try(2), sig_child);
    end
    % Flag nur eine Generation lang
    applyClusterSigmaThisGen = false;

    % ---- Selektion: Cover-first; optional μ+λ wenn (noch) kein feasible
    T = struct2table(kids);
    T = ensure_sigma_numeric(T);
    
    if cfg.useMuPlusLambdaWhenInfeas && ~any(T.feasible)
    P = struct2table(parents);
    P = ensure_sigma_numeric(P);
    U = [P; T];              % jetzt sind beide 'sigma' numerisch -> klappt
    else
    U = T;
    end


    feasU = U(U.feasible==true, :);
    if ~isempty(feasU)
        Usel = sortrows(feasU, {'cost'},{'ascend'});                  % feasible → Kosten
    else
        Usel = sortrows(U, {'cover','cost'},{'descend','ascend'});    % infeasible → Cover
    end

    % Elite-Schutz (bestes Cover bleibt erhalten)
    if cfg.keepBestCoverElite
        [~,idxElite] = max(U.cover);
        elite = U(idxElite,:);
        sel   = Usel(1:min(cfg.mu-1, height(Usel)), :);
        if height(sel)==0
            sel = elite;
        else
            already = ismember(elite{:,[1 2 4 5 6]}, sel{:,[1 2 4 5 6]}); % (E,P,cost,cover,feasible)
            if ~any(already)
                sel = [elite; sel];
            end
            sel = sel(1:min(cfg.mu,height(sel)),:);
        end
    else
        sel = Usel(1:min(cfg.mu,height(Usel)), :);
    end

    parents = table2struct(sel);

    % „bester bisher“ aktualisieren (feasible >> cover >> cost)
    if bestPar.feasible && ~sel.feasible(1)
        accBest = false;
    elseif ~bestPar.feasible && sel.feasible(1)
        accBest = true;
    elseif bestPar.feasible && sel.feasible(1)
        accBest = (sel.cost(1) < bestPar.cost - cfg.costTol);
    else
        accBest = (sel.cover(1) > bestPar.cover + cfg.coverTol) || ...
                  (abs(sel.cover(1)-bestPar.cover)<=cfg.coverTol && sel.cost(1) < bestPar.cost - cfg.costTol);
    end

    if accBest
        bestPar = struct('E',sel.E(1),'P',sel.P(1),'sigma',sel.sigma(1,:), ...
                         'cost',sel.cost(1),'cover',sel.cover(1),'feasible',sel.feasible(1));
        noImproveCounter = 0;
        bestCoverSoFar   = max(bestCoverSoFar, bestPar.cover);
    else
        noImproveCounter = noImproveCounter + 1;
    end

    % History
    [mSigE,mSigP] = sigma_means(sel.sigma);
    hist(gen,:)   = [gen, E_center, P_center, bestPar.cost, bestPar.cover, ...
                     double(bestPar.feasible), double(accBest), mSigE, mSigP];

    if cfg.verbose
        fprintf('Gen %03d: center(E=%.1f,P=%.1f)  best(E=%.1f,P=%.1f)  cost=%.1f  cover=%.3f  feas=%d%s\n', ...
            gen, E_center, P_center, bestPar.E, bestPar.P, bestPar.cost, bestPar.cover, bestPar.feasible, tern(accBest,' *',''));
    end


    %% ---- Stagnation & Restarts (feasible: Cluster, infeasible: kein Restart) ----
doBreak = false;

if bestPar.feasible
    % Feasible: Stagnation prüfen (Kosten + Cover)
    recent_cost  = hist(max(1,gen-5):gen, 4);
    recent_cover = hist(max(1,gen-5):gen, 5);
    dc = diff(recent_cost(:));  dc = dc(~isnan(dc));
    dv = diff(recent_cover(:)); dv = dv(~isnan(dv));
    
    stalledCosts = ~isempty(dc) && (max(abs(dc)) < 5*cfg.costTol);
    stalledCover = ~isempty(dv) && (max(abs(dv)) < 5*cfg.coverTol);
    
    longNoImprove = (noImproveCounter >= cfg.stallGen);


    if cfg.restartOnStall && (longNoImprove || (stalledCosts && stalledCover)) ...
                          && (restartCount < cfg.maxRestarts)
        restartCount = restartCount + 1;
        if cfg.verbose
            fprintf('  [Restart #%d] FEASIBLE stagnation -> multi-cluster around best (K=%d), sigma x%.1f\n', ...
                restartCount, cfg.clusterCount, cfg.clusterSigmaMul);
        end

       % --- FEASIBLE: Multi-Cluster-Restart um bestPar --------------------------
% K Cluster-Center rund um den aktuellen Besten erzeugen
centers = zeros(cfg.clusterCount, 2);
centers(1,:) = [bestPar.E, bestPar.P];  % Nukleus = Bestlösung
for k = 2:cfg.clusterCount
    centers(k,1) = clamp(bestPar.E*(1 + cfg.clusterRadiusRel*randn), cfg.E_bounds);
    centers(k,2) = clamp(bestPar.P*(1 + cfg.clusterRadiusRel*randn), cfg.P_bounds);
end

% Eltern auf Cluster verteilen + moderater lokaler Jitter
for i = 1:cfg.mu
    c = centers(1 + mod(i-1, cfg.clusterCount), :);
    parents(i).E = clamp(c(1) * (1 + cfg.restart_center_noise*randn), cfg.E_bounds);
    parents(i).P = clamp(c(2) * (1 + cfg.restart_center_noise*randn), cfg.P_bounds);

    % nur Cluster-Sigma-Multiplikator anwenden (keine weiteren Sigma-Faktoren)
    if isnumeric(parents(i).sigma)
        parents(i).sigma = parents(i).sigma * cfg.clusterSigmaMul;
    end

    % direkt bewerten, damit die nächste Generation auf frischen Werten läuft
    parents(i) = evalCandidate(parents(i).E, parents(i).P, parents(i).sigma);
end

% Zähler zurücksetzen, Cover-Referenz neu setzen, besten neu ziehen
noImproveCounter  = 0;
stallCoverCounter = 0;
bestCoverSoFar    = max([parents.cover]);
bestPar           = best_of(parents);


    elseif ~cfg.restartOnStall && (longNoImprove || (stalledCosts && stalledCover))
        doBreak = true; % keine Restarts gewünscht -> Abbruch
    end

else
    % --- INFEASIBLE: KEIN Restart ---
    % Nur Cover-Tracking + optional moderates Sigma-Aufbohren
    curBestCover = sel.cover(1);
    if (curBestCover < bestCoverSoFar + cfg.coverPriorityEps)
        stallCoverCounter = stallCoverCounter + 1;
    else
        bestCoverSoFar    = curBestCover;
        stallCoverCounter = 0;
    end

    % (Optional) σ leicht anheben, wenn's zäh wird – bleibt in deinem Code erhalten.
    if stallCoverCounter > round(cfg.stallGen/2)
        for i=1:numel(parents)
            if isnumeric(parents(i).sigma)
                parents(i).sigma = parents(i).sigma * 1.5;
            end
        end
    end

    % KEIN Restart im infeasible-Fall mehr!
end

if doBreak 
    break; 
end
end

hist = hist(1:gen,:);

%% ---------- Ergebnis bauen ----------
result = struct();
result.best_E_nom_kWh     = bestPar.E;
result.best_P_grid_max_kW = bestPar.P;
result.best_cost          = bestPar.cost;
result.best_cover         = bestPar.cover;
result.feasible           = bestPar.feasible;

H = array2table(hist, 'VariableNames', ...
    {'Gen','E_center','P_center','best_cost','best_cover','best_feasible','acceptedBest','meanSigmaE','meanSigmaP'});
result.history = H;
%% =================== NESTED HELFER ===================
function cand = evalCandidate(E, P, sigma_here)
    % --- für externes Skript / Debug ---
    assignin('base','Current_Battery_kWh',E);
    assignin('base','Current_GridPower_kW',P);

    % Parameter in Modell setzen ...
    assignin(mdlW,'E_nom',E);
    assignin(mdlW,'P_grid_max',P);
    if ~isempty(E0_kWh)
        IC = min(max(E0_kWh,0), E);
        try, set_param([modelName '/Int_Energy'],'InitialCondition', num2str(IC)); end
    end

   
    evalin('base', sprintf("sim('%s');", modelName));

    % ===== Vollzyklen berechnen (pro Kind) ==============================
    cycles_from_charge = NaN;
    cycles_throughput  = NaN;
    try
        Pi_raw = evalin('base','P_int_ws');         % To-Workspace Signal
        XYpi   = swt2xy_local(Pi_raw);              % -> struct .t .y
        dt     = diff(XYpi.t(:));                   % [s]
        Pmid   = XYpi.y(:); Pmid = Pmid(1:end-1);   % kW, auf dt-Raster kürzen

        % a) Nur geladene Energie: integrate max(P,0)
        Ein_kWh = sum( max(Pmid,0) .* dt ) / 3600;  % [kWh]
        cycles_from_charge = Ein_kWh / max(E,1e-9);

        % b) Throughput: ∫|P| dt / (2E)
        Ethr_kWh = sum( abs(Pmid) .* dt ) / 3600;   % [kWh]
        cycles_throughput  = Ethr_kWh / max(2*E,1e-9);

    catch
        % Fallback über Energiekurve
        try
            Eraw  = evalin('base','E_kWh_ws');
            XYe   = swt2xy_local(Eraw);
            dE    = diff(XYe.y(:));                 % [kWh] (diskret)
            dEpos = max(-dE,0);                     % Laden erhöht E -> -dE
            Ein_kWh = sum(dEpos);
            cycles_from_charge = Ein_kWh / max(E,1e-9);

            Ethr_kWh = sum(abs(dE));
            cycles_throughput  = Ethr_kWh / max(2*E,1e-9);
        catch
            % bleibt NaN
        end
    end

    % In den Workspace legen (für andere Skripte)
    assignin('base','Current_FullCycles_FromCharge', cycles_from_charge);
    assignin('base','Current_FullCycles_Throughput', cycles_throughput);
    % ===================================================================

    % Unserved lesen & Cover bewerten (wie bisher)
    U_raw    = evalin('base','Unserved_ws');
    cover    = cover_on_profile(t_seconds, load_kW, U_raw, cfg.minServeRatio);
    feasible = (cover >= cfg.targetCoverFrac);

    % === NEU: €/kW und €/kWh können Skalar ODER Funktions-Handle sein ===
    if isa(cfg.c_grid, 'function_handle')
        c_grid_here = cfg.c_grid(P);     % €/kW passend zur aktuellen Netzleistung P
    else
        c_grid_here = cfg.c_grid;        % fixer €/kW
    end

    if isa(cfg.c_batt, 'function_handle')
        c_batt_here = cfg.c_batt(E);     % €/kWh passend zur aktuellen Kapazität E
    else
        c_batt_here = cfg.c_batt;        % fixer €/kWh
    end

    % (optional) Debug in Base-Workspace
    assignin('base','Current_EUR_per_kW_grid',  c_grid_here);
    assignin('base','Current_EUR_per_kWh_batt', c_batt_here);

    % Kostenfunktion (linear; erweitere bei Bedarf um Penalties etc.)
    grid_cost = c_grid_here * P;         % entspricht Total_withBKZ(P)
    batt_cost = c_batt_here * E;
    cost      = grid_cost + batt_cost;

    cand = struct('E',E,'P',P,'sigma',sigma_here, ...
                  'cost',cost,'cover',cover,'feasible',feasible);
end




Ptab  = struct2table(parents);
keep  = intersect({'E','P','sigma','cost','cover','feasible'}, Ptab.Properties.VariableNames, 'stable');
result.parents = Ptab(:, keep);

fprintf('\n==> Ergebnis: E=%.2f kWh, G=%.2f kW, cost=%.2f €, cover=%.3f, feasible=%d\n', ...
    bestPar.E, bestPar.P, bestPar.cost, bestPar.cover, bestPar.feasible);




function b = best_of(S)
    T_ = struct2table(S);
    T_.feasRank = double(T_.feasible);
    T_ = sortrows(T_, {'feasRank','cost','cover'}, {'descend','ascend','descend'});
    b  = table2struct(T_(1,:));
end

function coverFrac = cover_on_profile(t_in, load_in, Uin, minServeRatio)
    XY = swt2xy_local(Uin);
    u_eval = interp1(XY.t(:), XY.y(:), t_in(:), 'previous', 'extrap');
    den = max(load_in(:), 1e-6);
    sr  = (load_in(:) - u_eval(:)) ./ den;
    sr(load_in(:) < 1e-6) = 1;
    coverFrac = mean(sr >= minServeRatio);
end

function XY = swt2xy_local(S)
    if isstruct(S) && isfield(S,'time') && isfield(S,'signals')
        t = S.time(:); v = S.signals.values;
    elseif isstruct(S) && isfield(S,'signals') && isfield(S.signals,'values')
        assert(evalin('base','exist(''tout'',''var'')')==1, 'Structure ohne Zeit: "tout" fehlt.');
        t = evalin('base','tout(:)'); v = S.signals.values;
    elseif isa(S,'timeseries')
        t = S.Time(:); v = S.Data;
    elseif isa(S,'Simulink.SimulationData.Dataset')
        assert(S.numElements>0,'Dataset ist leer.');
        idx = 1;
        for k=1:S.numElements
            nm = string(S.getElement(k).Name);
            bp = S.getElement(k).BlockPath; p = "";
            try, p = string(bp.getBlock(1)); end
            if contains(nm,"Unserved","IgnoreCase",true) || contains(p,"Unserved","IgnoreCase",true)
                idx = k; break;
            end
        end
        V = S.getElement(idx).Values; t = V.Time(:); v = V.Data(:);
    elseif isnumeric(S) && ~isempty(S)
        assert(evalin('base','exist(''tout'',''var'')')==1, 'Array ohne "tout".');
        t = evalin('base','tout(:)'); v = S(:);
    elseif isa(S,'timetable')
        t = S.Time(:); vars = setdiff(S.Properties.VariableNames, {'Time'}); v = S.(vars{1})(:);
    elseif istable(S)
        assert(evalin('base','exist(''tout'',''var'')')==1, 'table ohne "tout".');
        t = evalin('base','tout(:)'); v = S{:,1};
    else
        error('Unserved_ws: unerwartetes Format (%s).', class(S));
    end
    if ismatrix(v) && size(v,2) > 1, v = v(:,1); end
    XY.t = t(:); XY.y = v(:);
end

function z = clamp(x, bounds), z = min(max(x, bounds(1)), bounds(2)); end
function r = unif(a,b), r = a + (b-a)*rand; end
function s = tern(c,a,b), if c, s=a; else, s=b; end, end
function [mE,mP] = sigma_means(sigcol)
    if istable(sigcol), S = table2array(sigcol);
    elseif iscell(sigcol), S = cell2mat(sigcol);
    else, S = sigcol; end
    if isempty(S), mE=NaN; mP=NaN; return; end
    if isvector(S) && numel(S)==2, mE=S(1); mP=S(2); else, mE=mean(S(:,1)); mP=mean(S(:,2)); end
end
function v = getf(s, field, default)
    if nargin<3, default=[]; end
    if ~isempty(s) && isfield(s,field) && ~isempty(s.(field)), v = s.(field); else, v = default; end
end
function T = ensure_sigma_numeric(T)
    if ~istable(T), return; end
    if ~ismember('sigma', T.Properties.VariableNames)
        T.sigma = nan(height(T),2);
        return;
    end
    if iscell(T.sigma)
        try
            T.sigma = cell2mat(T.sigma);  % erwartet 1x2 double je Zelle
        catch
            % Fallback, wenn mal was Komisches drin ist:
            n = height(T);
            S = nan(n,2);
            for ii = 1:n
                v = T.sigma{ii};
                if isnumeric(v) && numel(v)==2
                    S(ii,:) = v(:).';
                end
            end
            T.sigma = S;
        end
    elseif isnumeric(T.sigma)
        % ok
    else
        T.sigma = nan(height(T),2);
    end
end

end
