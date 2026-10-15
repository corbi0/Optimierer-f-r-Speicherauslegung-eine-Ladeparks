function result = optimize_battery_grid_ES_mu_lambda_preisfunktion_stufen(modelName, t_seconds, load_kW, opts)
% OPTIMIZE_BATTERY_GRID_ES_MU_LAMBDA_PREISFUNKTION_STUFEN
%
% Diese Funktion implementiert exakt die gleiche (μ,λ)-Evolutionsstrategie
% wie ``optimize_battery_grid_ES_mu_lambda_preisfunktion``, verwendet
% jedoch stufenweise Kostenfunktionen für den Netzanschluss und die
% Batterie. Der Algorithmus bleibt ansonsten unverändert: es wird auf
% dem gegebenen Lastprofil die Deckungsquote bewertet und die Kosten
% (Batterie + Netz) minimiert. Die Parametrierung erfolgt vollständig
% über das options-Struct ``opts``, insbesondere die Funktionshandles
% ``opts.c_grid`` und ``opts.c_batt`` sollten auf die hier bereitgestellten
% stufenweisen Preisfunktionen zeigen (z. B. ``grid_eur_per_kW_stufen``
% bzw. ``batt_eur_per_kWh_stufen``).
%
% Für die Beschreibung der Ein- und Ausgaben siehe die ursprüngliche
% Optimiererfunktion. Änderungen an der Logik (Mutation, Selektion,
% Stall‑Handling, Multi‑Cluster‑Restarts etc.) wurden bewusst
% vermieden.

%% ---------- Konfiguration laden ----------
cfg.c_batt          = getf(opts,'c_batt',80);
cfg.c_grid          = getf(opts,'c_grid',200);
cfg.targetCoverFrac = getf(opts,'targetCoverFrac',0.95);
cfg.minServeRatio   = getf(opts,'minServeRatio',0.90);

cfg.mu              = getf(opts,'mu',3);
cfg.lambda          = getf(opts,'lambda',12);

cfg.mode            = getf(opts,'mode','selfadapt');
cfg.sigma0          = getf(opts,'sigma0',[0.2 0.2]);
cfg.sigmaMinRel     = getf(opts,'sigmaMinRel',0.01);
cfg.sigmaMaxRel     = getf(opts,'sigmaMaxRel',0.8);

cfg.stepE_kWh       = getf(opts,'stepE_kWh',[10 40]);
cfg.stepP_kW        = getf(opts,'stepP_kW',[5 20]);

cfg.E_bounds        = getf(opts,'E_bounds',[1 Inf]);
cfg.P_bounds        = getf(opts,'P_bounds',[1 Inf]);

cfg.maxGen          = getf(opts,'maxGen',200);
cfg.verbose         = getf(opts,'verbose',true);
cfg.rngSeed         = getf(opts,'rngSeed',[]);
cfg.costTol         = getf(opts,'costTol',1e-2);
cfg.coverTol        = getf(opts,'coverTol',1e-4);

% --- Deine gewünschte, schlanke Steuerung ---
cfg.sigmaMul        = getf(opts,'sigmaMul',1.0);
cfg.clusterRadiusRel= getf(opts,'clusterRadiusRel',0.20);
cfg.clusterSigmaMul = getf(opts,'clusterSigmaMul',1.0);

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
    set_param(modelName,'FastRestart','off');     % Rebuild nur 1×
    set_param(modelName,'SimulationCommand','update'); % genau 1× vor Start 
end
mdlW = get_param(modelName,'ModelWorkspace');

Load_ts = timeseries(load_kW(:), t_seconds(:));
assignin('base','Load_ts',Load_ts);
try set_param(modelName,'StopTime',num2str(t_seconds(end))); end

%% ---------- Eltern initialisieren ----------
% Eltern initialisieren.  Zusätzlich zu E, P, sigma, cost, cover und
% feasible werden auch Felder für die Vollzyklen reserviert, damit alle
% Kandidaten dieselbe Struktur haben.  Dadurch lassen sich spätere
% Zuweisungen vermeiden (siehe Fehlermeldung "Subscripted assignment
% between dissimilar structures").
parents = repmat(struct('E',E0,'P',P0,'sigma',[NaN NaN], ...
                        'cost',NaN,'cover',NaN,'feasible',false, ...
                        'cycles_throughput', NaN, 'cycles_from_charge', NaN), cfg.mu,1);

if strcmpi(cfg.mode,'selfadapt')
    sigma_abs = max([1 1], abs(x0).*cfg.sigma0(:)');
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
    % Die Struktur der Kinder muss alle Felder enthalten, die auch
    % evalCandidate zurückliefert.  Andernfalls führt das Zuweisen
    % eines Kandidaten mit zusätzlichen Feldern (z. B. cycles_*) zu
    % „Subscripted assignment between dissimilar structures“.  Wir
    % initialisieren daher auch die Vollzyklus-Felder mit NaN.
    kids(cfg.lambda,1) = struct('E',[], 'P', [], 'sigma', [], 'cost', [], 'cover', [], 'feasible', [], ...
                                'cycles_throughput', NaN, 'cycles_from_charge', NaN);
    for j = 1:cfg.lambda
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
        Ptab = struct2table(parents);
        Ptab = ensure_sigma_numeric(Ptab);
        U = [Ptab; T];
    else
        U = T;
    end

    feasU = U(U.feasible == true, :);
    if ~isempty(feasU)
        Usel = sortrows(feasU, {'cost'},{'ascend'});
    else
        Usel = sortrows(U, {'cover','cost'},{'descend','ascend'});
    end

    % Elite-Schutz (bestes Cover bleibt erhalten)
    if cfg.keepBestCoverElite
        [~,idxElite] = max(U.cover);
        elite = U(idxElite,:);
        sel   = Usel(1:min(cfg.mu-1, height(Usel)), :);
        if height(sel) == 0
            sel = elite;
        else
            already = ismember(elite{:,[1 2 4 5 6]}, sel{:,[1 2 4 5 6]});
            if ~any(already)
                sel = [elite; sel];
            end
            sel = sel(1:min(cfg.mu, height(sel)),:);
        end
    else
        sel = Usel(1:min(cfg.mu, height(Usel)), :);
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
                         'cost',sel.cost(1),'cover',sel.cover(1),'feasible',sel.feasible(1), ...
                         'cycles_throughput', sel.cycles_throughput(1), 'cycles_from_charge', sel.cycles_from_charge(1));
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
            centers = zeros(cfg.clusterCount, 2);
            centers(1,:) = [bestPar.E, bestPar.P];  % Nukleus = Bestlösung
            for k = 2:cfg.clusterCount
                centers(k,1) = clamp(bestPar.E * (1 + cfg.clusterRadiusRel*randn), cfg.E_bounds);
                centers(k,2) = clamp(bestPar.P * (1 + cfg.clusterRadiusRel*randn), cfg.P_bounds);
            end
            % Eltern auf Cluster verteilen + moderater lokaler Jitter
            for i = 1:cfg.mu
                c = centers(1 + mod(i-1, cfg.clusterCount), :);
                parents(i).E = clamp(c(1) * (1 + cfg.restart_center_noise*randn), cfg.E_bounds);
                parents(i).P = clamp(c(2) * (1 + cfg.restart_center_noise*randn), cfg.P_bounds);
                % nur Cluster-Sigma-Multiplikator anwenden
                if isnumeric(parents(i).sigma)
                    parents(i).sigma = parents(i).sigma * cfg.clusterSigmaMul;
                end
                % direkt bewerten
                parents(i) = evalCandidate(parents(i).E, parents(i).P, parents(i).sigma);
            end
            % Zähler zurücksetzen
            noImproveCounter  = 0;
            stallCoverCounter = 0;
            bestCoverSoFar    = max([parents.cover]);
            bestPar           = best_of(parents);
        elseif ~cfg.restartOnStall && (longNoImprove || (stalledCosts && stalledCover))
            doBreak = true; % keine Restarts -> Abbruch
        end
    else
        % --- INFEASIBLE: KEIN Restart ---
        curBestCover = sel.cover(1);
        if (curBestCover < bestCoverSoFar + cfg.coverPriorityEps)
            stallCoverCounter = stallCoverCounter + 1;
        else
            bestCoverSoFar    = curBestCover;
            stallCoverCounter = 0;
        end
        % (Optional) σ leicht anheben
        if stallCoverCounter > round(cfg.stallGen/2)
            for i = 1:numel(parents)
                if isnumeric(parents(i).sigma)
                    parents(i).sigma = parents(i).sigma * 1.5;
                end
            end
        end
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
% Vollzyklen (Throughput und aus Ladeenergie) für die beste Lösung
if isfield(bestPar, 'cycles_throughput')
    result.best_cycles_throughput = bestPar.cycles_throughput;
end
if isfield(bestPar, 'cycles_from_charge')
    result.best_cycles_from_charge = bestPar.cycles_from_charge;
end
H = array2table(hist, 'VariableNames', ...
    {'Gen','E_center','P_center','best_cost','best_cover','best_feasible','acceptedBest','meanSigmaE','meanSigmaP'});
result.history = H;
Ptab  = struct2table(parents);
keep  = intersect({'E','P','sigma','cost','cover','feasible'}, Ptab.Properties.VariableNames, 'stable');
result.parents = Ptab(:, keep);

fprintf('\n==> Ergebnis: E=%.2f kWh, G=%.2f kW, cost=%.2f €, cover=%.3f, feasible=%d\n', ...
    bestPar.E, bestPar.P, bestPar.cost, bestPar.cover, bestPar.feasible);

%% =================== NESTED HELFER ===================
    function cand = evalCandidate(E, P, sigma_here)
        % --- Stufung von Batteriegröße und Netzanschlussleistung ---
        % Batteriekapazität und Netzanschluss werden auf die nächsthöhere
        % Container- bzw. Trafo-Stufe aufgerundet.  Die Simulation und die
        % Kostenberechnung basieren auf diesen gerundeten Werten.  Damit
        % wird das volle Potenzial der installierten Leistung genutzt.
        E_snap = snap_batt(E);
        P_snap = snap_grid(P, cfg.baseSite, cfg.priceLib);

        % --- für externes Skript / Debug ---
        assignin('base','Current_Battery_kWh', E_snap);
        assignin('base','Current_GridPower_kW',  P_snap);
        % Parameter in Modell setzen ...
        assignin(mdlW,'E_nom', E_snap);
        assignin(mdlW,'P_grid_max', P_snap);
        if ~isempty(E0_kWh)
            IC = min(max(E0_kWh, 0), E_snap);
            try, set_param([modelName '/Int_Energy'], 'InitialCondition', num2str(IC)); end
        end
        % Simulation durchführen
        evalin('base', sprintf("sim('%s');", modelName));
        % Zyklenberechnung
        cycles_from_charge = NaN;
        cycles_throughput  = NaN;
        try
            Pi_raw = evalin('base','P_int_ws');
            XYpi   = swt2xy_local(Pi_raw);
            dt_i   = diff(XYpi.t(:));
            Pmid   = XYpi.y(:); Pmid = Pmid(1:end-1);
            Ein_kWh = sum( max(Pmid,0) .* dt_i ) / 3600;
            cycles_from_charge = Ein_kWh / max(E,1e-9);
            Ethr_kWh = sum( abs(Pmid) .* dt_i ) / 3600;
            cycles_throughput  = Ethr_kWh / max(2*E,1e-9);
        catch
            try
                Eraw  = evalin('base','E_kWh_ws');
                XYe   = swt2xy_local(Eraw);
                dE    = diff(XYe.y(:));
                dEpos = max(-dE,0);
                Ein_kWh = sum(dEpos);
                cycles_from_charge = Ein_kWh / max(E,1e-9);
                Ethr_kWh = sum(abs(dE));
                cycles_throughput  = Ethr_kWh / max(2*E,1e-9);
            catch
                % bleibt NaN
            end
        end
        assignin('base','Current_FullCycles_FromCharge', cycles_from_charge);
        assignin('base','Current_FullCycles_Throughput', cycles_throughput);
        U_raw    = evalin('base','Unserved_ws');
        cover    = cover_on_profile(t_seconds, load_kW, U_raw, cfg.minServeRatio);
        feasible = (cover >= cfg.targetCoverFrac);
        % --- stufenweise Preisfunktionen ---
        if isa(cfg.c_grid, 'function_handle')
            c_grid_here = cfg.c_grid(P_snap);
        else
            c_grid_here = cfg.c_grid;
        end
        if isa(cfg.c_batt, 'function_handle')
            c_batt_here = cfg.c_batt(E_snap);
        else
            c_batt_here = cfg.c_batt;
        end
        assignin('base','Current_EUR_per_kW_grid',  c_grid_here);
        assignin('base','Current_EUR_per_kWh_batt', c_batt_here);
        % Kostensummen: multipliziere mit den gerundeten Werten, um die
        % Gesamtkosten der jeweiligen Stufe zu erhalten.
        grid_cost = c_grid_here * P_snap;
        batt_cost = c_batt_here * E_snap;
        cost      = grid_cost + batt_cost;
        % Candidate speichern mit den gerundeten Größen
        cand = struct('E', E_snap, 'P', P_snap, 'sigma', sigma_here, ...
                      'cost', cost, 'cover', cover, 'feasible', feasible, ...
                      'cycles_throughput', cycles_throughput, ...
                      'cycles_from_charge', cycles_from_charge);
    end

    %% ---------- Lokale Helfer für Stufung ----------
    function E_step = snap_batt(E_in)
        % Batterie-Kapazität auf Containerstufen aufrunden.  Die EnerX‑Einheit
        % besitzt 5.64 MWh pro Container (entsprechend CATL EnerX, 4‑h‑System),
        % sodass sich pro Container eine Leistung von 1.41 MW ergibt.  Diese
        % Größe sollte mit der Degradation/Ersatzlogik aus compute_bess_lifetime
        % übereinstimmen.
        E_unit_MWh  = 5.64;      % [MWh] pro Container
        E_unit_kWh  = E_unit_MWh * 1e3; % [kWh]
        n_units     = max(1, ceil(E_in / E_unit_kWh));
        E_step      = n_units * E_unit_kWh;
    end

    function P_step = snap_grid(P_in, baseSite, priceLib)
        % Netzanschlussleistung auf die nächsthöhere Trafo-Stufe aufrunden.
        % Hierzu wird dieselbe Logik wie in grid_eur_per_kW_stufen
        % verwendet: Für kleine Leistungen (<7.5 MW) wird die einfache
        % Trafoauswahl ohne N-1-Redundanz genutzt, für große Leistungen
        % eine Kombination mit Redundanz.
        if nargin < 3 || isempty(priceLib)
            priceLib = defaultPriceLib_stufen();
        end
        if nargin < 2 || isempty(baseSite)
            baseSite = struct();
        end
        n1_threshold_kW = 7500;
        trafo_lib = priceLib.trafo_lib;
        if P_in >= n1_threshold_kW
            trafo_set = pick_transformers_n1_stufen(P_in, trafo_lib, 1.0, 2);
        else
            trafo_set = pick_transformers_simple_stufen(P_in, trafo_lib);
        end
        P_step = sum([trafo_set.S]) * 1e3;
    end

    function trafo_set = pick_transformers_simple_stufen(total_kW, trafo_lib)
        % Einfache Trafoauswahl ohne N-1
        P_MW = total_kW / 1e3;
        cpm = arrayfun(@(t) t.price / t.S, trafo_lib);
        [~, ord] = sort(cpm, 'ascend');
        need = P_MW;
        chosen = [];
        for k = 1:numel(ord)
            t = trafo_lib(ord(k));
            n = floor(need / t.S);
            if need > 0 && n == 0
                n = 1;
            end
            chosen = [chosen, repmat(t,1,n)];
            need = need - n * t.S;
            if need <= 0
                break;
            end
        end
        if need > 0
            [~, imax] = max([trafo_lib.S]);
            chosen = [chosen, trafo_lib(imax)];
        end
        trafo_set = chosen;
    end

    function trafo_set = pick_transformers_n1_stufen(total_kW, trafo_lib, n1_fraction, min_trafos)
        % Trafoauswahl mit N-1-Redundanz
        P_MW = total_kW / 1e3;
        bestCost = inf;
        bestSet = [];
        maxUnits = 8;
        for n1 = 0:maxUnits
            for n2 = 0:maxUnits
                for n3 = 0:maxUnits
                    if n1 + n2 + n3 == 0
                        continue;
                    end
                    set = [repmat(trafo_lib(1),1,n1), repmat(trafo_lib(2),1,n2), repmat(trafo_lib(3),1,n3)];
                    if numel(set) < min_trafos
                        continue;
                    end
                    totalS = sum([set.S]);
                    if totalS < P_MW
                        continue;
                    end
                    [~, imax] = max([set.S]);
                    remaining = totalS - set(imax).S;
                    if remaining < n1_fraction * P_MW
                        continue;
                    end
                    cost = sum([set.price]);
                    if cost < bestCost
                        bestCost = cost;
                        bestSet = set;
                    end
                end
            end
        end
        if isempty(bestSet)
            bestSet = pick_transformers_simple_stufen(total_kW, trafo_lib);
            while numel(bestSet) < min_trafos
                [~, imax] = max([trafo_lib.S]);
                bestSet = [bestSet, trafo_lib(imax)];
            end
        end
        trafo_set = bestSet;
    end

    function lib = defaultPriceLib_stufen()
        % Lokale Kopie der Standard-Preisparameter (wie in grid_batt_step_functions)
        lib = struct();
        lib.trench.regular_per_m = 200;
        lib.trench.autobahn.offset  = 20000; lib.trench.autobahn.per_m  = 200;
        lib.trench.gewaesser.offset = 50000; lib.trench.gewaesser.per_m = 300;
        lib.trench.strasse.offset   = 10000; lib.trench.strasse.per_m   = 180;
        lib.material.schutzrohr_per_m = 46.30;
        lib.material.ms_joint_per_pc  = 289.91;
        lib.material.ms_end_per_pc    = 162.39;
        lib.station.per_station_base     = 50000;
        lib.station.per_field            = 20000;
        lib.station.earthing             = 50000;
        lib.station.testing              = 45000;
        lib.station.engineering_per_MW   = 15000;
        lib.station.ehouse               = 300000;
        lib.trafo_lib = [ ...
            struct('S', 4.0, 'price', 230000); ...
            struct('S', 6.3, 'price', 350000); ...
            struct('S', 10.0, 'price', 500000) ...
        ];
        lib.nshv.base_2trafos     = 200000;
        lib.nshv.per_extra_trafo  = 0;
        lib.dso.abgang_per_field  = 120000;
        lib.dso.bkz_per_kw        = 110;
    end
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
    function z = clamp(x, bounds)
        z = min(max(x, bounds(1)), bounds(2));
    end
    function r = unif(a,b)
        r = a + (b-a)*rand;
    end
    function s = tern(c,a,b)
        if c, s=a; else, s=b; end
    end
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
                T.sigma = cell2mat(T.sigma);
            catch
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