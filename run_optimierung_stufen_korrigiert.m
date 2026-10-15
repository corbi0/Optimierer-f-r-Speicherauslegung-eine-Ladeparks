%% Ausführung für stufenweise Preisfunktionen
% Dieses Skript ruft den Evolutionsstrategien‑Optimierer
% ``optimize_battery_grid_ES_mu_lambda_preisfunktion_stufen`` mit
% stufenweise definierten Kostenfunktionen für Netzanschluss und
% Batteriespeicher auf. Es stellt sicher, dass der Optimierer keine
% Zwischenwerte (lineare Skalierung) mehr verwendet, sondern immer auf
% die nächsthöhere Trafo‑ oder Batterieeinheit abrundet.
%
% - Lastprofil wird EINMAL über build_load_profile(site_name) erzeugt
% - t‑Achse in Stunden (0.25‑Raster), From‑Workspace‑Block interpoliert
% - fester Simulink‑Schritt dt = 10

%% 0) Schrittweite
dt = 10;  % [s]

%% 1) Standortwahl
% "GoldeneBremm_Sued" | "TecklenburgerLand_West" | "Hochwald_West" | "Inntal_West"
site_name = "Inntal_West";

% EINMAL Lastprofil bauen
[t15, P_15min] = build_load_profile(site_name, false);

% Variablen wie früher bereitstellen
time_day = t15;        % Stunden (0, 0.25, ...)
P_load   = P_15min;    % kW (mittlere 15‑min Leistung)

% (Optional) Legacy‑Namen für vollständige Kompatibilität:
assignin('base','t15', time_day);
assignin('base','E_scaled_15min', P_load);

%% 1a) Solver/Modelleinstellungen
modelName = 'Battery_PowerEnergy_GridSOC_netz';
if ~bdIsLoaded(modelName), open_system(modelName); end
set_param(modelName, ...
    'SolverType','Fixed-step', ...
    'Solver','ode3', ...
    'FixedStep', num2str(dt), ...
    'StopTime', num2str(time_day(end)), ...   % z. B. 8759.5
    'MaxConsecutiveMinStep','1000');

% Wenn dein From‑Workspace‑Block zwei getrennte Variablen nutzt:
%   Zeit = 'time_day', Daten = 'P_load', Interpolate = on (inherit).
assignin('base','time_day', time_day);
assignin('base','P_load',   P_load);

%% 2) Standort‑Info (nur für Logging)
baseSite  = pick_site_by_name(site_name);

% Preisbibliothek initialisieren.  Da ``grid_eur_per_kW_stufen`` den
% dritten Parameter optional mit einem internen Default belegt, genügt hier
% ein leerer Struct.  Dieser wird auch im Options‑Struct gespeichert, damit
% der Optimierer die Trafostufung korrekt verwenden kann.
priceLib = [];

%% 2) Optionen / Startwerte
opts = struct;
opts.E_nom_kWh0      = 10000;   % Start-Batteriegröße
opts.P_grid_max_kW0  = 5000;    % Start-Netzanschluss
opts.E0_kWh          = 2000;    % Startenergie absolut (kWh)

% Für stufenbasierte Berechnungen (z. B. Trafo-Stufung) benötigt der
% Optimierer Zugriff auf den Standort und die Preisbibliothek.  Daher
% speichern wir diese Informationen im options‑Struct.
opts.baseSite = baseSite;
opts.priceLib = priceLib;

% Stufenfunktionen für €/kW und €/kWh
% Übergabe der Preisbibliothek an grid_eur_per_kW_stufen nicht nötig, da
% optionaler Parameter mit Default versehen ist. Nur Standort übergeben.
opts.c_grid = @(P_kW) grid_eur_per_kW_stufen(P_kW, baseSite);
opts.c_batt = @(E_kWh) batt_eur_per_kWh_stufen(E_kWh);

% Zielkriterien
opts.targetCoverFrac = 0.95;
opts.minServeRatio   = 0.90;

% Evolutionsstrategie Parameter
opts.mode        = 'selfadapt';
opts.sigma0      = [0.07 0.07];
opts.sigmaMinRel = 0.01;
opts.sigmaMaxRel = 0.6;
opts.E_bounds    = [50 1e7];
opts.P_bounds    = [50 1e7];
opts.mu          = 3;
opts.lambda      = 30;
opts.maxGen      = 5;
opts.verbose     = true;
opts.rngSeed     = 1;
opts.costTol     = 1e-2;
opts.coverTol    = 1e-4;
opts.stallGen    = 30;

%% 3) Optimierung starten
res = optimize_battery_grid_ES_mu_lambda_preisfunktion_stufen(modelName, time_day, P_load, opts);

%% 4) Ergebnis ausgeben
fprintf('\n=== Global-Best Ergebnis (Stufen) ===\n');
fprintf('Standort: %s\n', string(site_name));
fprintf('Batterie: %.1f kWh\n', res.best_E_nom_kWh);
fprintf('Netz    : %.1f kW\n',  res.best_P_grid_max_kW);
fprintf('Kosten  : %.1f €\n',   res.best_cost);
fprintf('Cover   : %.3f (feasible=%d)\n', res.best_cover, res.feasible);

% --- 7) Batterie-Lebensdauer berechnen ---
% Für die beste Lösung wird die Lebensdauer (Ersatzjahr) anhand der
% Vollzyklen pro Jahr und der Batteriegröße bestimmt.  Hierzu wird
% compute_bess_lifetime() aufgerufen, das die Containeranzahl sowie
% Degradation und Ersatzzeitpunkt berechnet.
try
    if isfield(res, 'best_cycles_throughput')
        lifetime = compute_bess_lifetime(res.best_E_nom_kWh, res.best_cycles_throughput);
        fprintf('\n--- BESS-Lebensdauer ---\n');
        fprintf('Benötigte Container: %d\n', lifetime.n_units);
        fprintf('Gesamtenergie : %.1f MWh\n', lifetime.E_total_MWh);
        fprintf('Gesamtleistung: %.1f MW\n',  lifetime.P_total_MW);
        % Ersatzjahr ausgeben oder Hinweis, wenn kein gültiger Wert vorliegt
        if isfield(lifetime, 'replacement_year') && ~isempty(lifetime.replacement_year) && ...
                isnumeric(lifetime.replacement_year) && ~isnan(lifetime.replacement_year)
            fprintf('Ersatzjahr bei %.0f%% Restkapazität: Jahr %.0f\n', ...
                    100 * lifetime.deg.params.EoL_frac, lifetime.replacement_year);
        else
            fprintf('Ersatzjahr bei %.0f%% Restkapazität: nicht verfügbar\n', ...
                    100 * lifetime.deg.params.EoL_frac);
        end
    end
catch ME
    warning('Lebensdauerberechnung fehlgeschlagen: %s', ME.message);
end

%% 5) Verlaufsplots
try
    H = res.history;
    figure('Name','ES-Verlauf (Stufen)','Color','w');
    tiledlayout(2,1,'Padding','compact','TileSpacing','compact');
    nexttile; plot(H.Gen, H.best_cost, '-o'); grid on;
    xlabel('Generation'); ylabel('Kosten [€]');
    title('Bester Kind-Score je Generation (Kosten)');
    nexttile; plot(H.Gen, H.best_cover, '-o'); grid on;
    xlabel('Generation'); ylabel('Cover');
    title('Bester Kind-Score je Generation (Cover)');
catch
    warning('History-Plot übersprungen.');
end

%% 6) Kosten-Breakdown-Plot
try
    % Netz-Kosten für bestes P
    Sbest     = baseSite;
    Sbest.kW  = res.best_P_grid_max_kW;
    Rbest     = ev_costs_single_model_v6(Sbest, priceLib, 'verbose', false);
    grid_parts   = [Rbest.A, Rbest.B, Rbest.C, Rbest.D];
    grid_labels  = {'A Trasse/Kabel','B Station/Trafo','C DSO-Abgang','D BKZ'};

    % Batterie-Kosten konsistent zu opts.c_batt
    bout = bess_costs_from_E(res.best_E_nom_kWh);
    batt_parts  = [bout.capex_breakdown.DC, bout.capex_breakdown.PCS, ...
                   bout.capex_breakdown.BOS, bout.capex_breakdown.EPC, ...
                   bout.capex_breakdown.SOFT, bout.capex_breakdown.SITE];
    batt_labels = {'DC (Batterie)','PCS','BOS','EPC','SOFT','SITE'};

    figure('Name','Kosten-Zusammensetzung (Stufen)','Color','w');
    % Separate Balken für Netz und Batterie zeichnen, damit unterschiedliche
    % Komponentenanzahlen (4 vs. 6) kein Problem darstellen
    hold on;
    bar(1, grid_parts, 'stacked');
    bar(2, batt_parts, 'stacked');
    hold off;
    grid on;
    xticks([1 2]);
    xticklabels({'Netz (A–D)','Batterie'});
    ylabel('Kosten [€]');
    title(sprintf('Kosten-Zusammensetzung | %s | P*=%.0f kW, E*=%.0f kWh', ...
           string(site_name), res.best_P_grid_max_kW, res.best_E_nom_kWh));
    legend([grid_labels, batt_labels], 'Location','bestoutside');
    % Totals als Text
    y_totals = [sum(grid_parts), sum(batt_parts)];
    for i = 1:numel(y_totals)
        text(i, y_totals(i) * 1.02, sprintf('%.0f €', y_totals(i)), ...
             'HorizontalAlignment','center','FontWeight','bold');
    end
    % Spezifische Kosten ausgeben
    fprintf('\n--- Spezifische Kosten (berechnet mit Stufen) ---\n');
    fprintf('Netz:  %.1f €/kW (inkl. BKZ)\n', Rbest.EUR_per_kW_withBKZ);
    fprintf('Batt:  %.1f €/kWh (gesamt CAPEX)\n', bout.capex_total_per_kWh);
catch ME
    warning('Breakdown-Plot fehlgeschlagen: %s', ME.message);
end

%% ================= Lokale Helper (Site-Auswahl & Batteriekosten) =================
function S = pick_site_by_name(name)
    switch string(name)
        case "GoldeneBremm_Sued"
            S = struct('name',"GoldeneBremm_Sued",'kW',1000,'route_m',6066, ...
                       'L_auto_m',0,'L_gewaesser_m',90,'L_strasse_m',45,'double_feed',[],'force_voltage_kV',[]);
        case "TecklenburgerLand_West"
            S = struct('name',"TecklenburgerLand_West",'kW',1000,'route_m',4288, ...
                       'L_auto_m',0,'L_gewaesser_m',0,'L_strasse_m',15,'double_feed',[],'force_voltage_kV',[]);
        case "Hochwald_West"
            S = struct('name',"Hochwald_West",'kW',1000,'route_m',6055, ...
                       'L_auto_m',0,'L_gewaesser_m',0,'L_strasse_m',15,'double_feed',[],'force_voltage_kV',[]);
        case "Inntal_West"
            S = struct('name',"Inntal_West",'kW',1000,'route_m',13322, ...
                       'L_auto_m',20,'L_gewaesser_m',75,'L_strasse_m',0,'double_feed',[],'force_voltage_kV',[]);
        otherwise
            error('Unbekannter Standortname: %s', name);
    end
end

function eur_per_kw = grid_eur_per_kW(P_kW, baseSite, priceLib)
    % Kein Cache während wir debuggen
    S = baseSite; S.kW = P_kW;
    R = ev_costs_single_model_v6(S, priceLib, 'verbose', false);
    eur_per_kw = R.EUR_per_kW_withBKZ;
    assignin('base','DBG_grid_last',R);
end

function eur_per_kWh = batt_eur_per_kWh_from_scaler(E_kWh)
    E_unit_MWh  = 5.64;
    P_unit_MW   = E_unit_MWh/4;
    E_total_MWh = E_kWh/1000;
    n_units     = max(1, ceil(E_total_MWh / E_unit_MWh));
    p = struct();
    p.E_unit_MWh = E_unit_MWh;
    p.P_unit_MW  = P_unit_MW;
    p.n_units    = n_units;
    out = bess_cost_scaler(p);
    eur_per_kWh = out.capex_total_per_kWh;
    assignin('base','DBG_batt_last_out', out);
end

function bout = bess_costs_from_E(E_kWh)
    E_unit_MWh  = 5.64;
    P_unit_MW   = E_unit_MWh/4;
    E_total_MWh = E_kWh/1000;
    n_units     = max(1, ceil(E_total_MWh / E_unit_MWh));
    p = struct();
    p.E_unit_MWh = E_unit_MWh;
    p.P_unit_MW  = P_unit_MW;
    p.n_units    = n_units;
    bout = bess_cost_scaler(p);
end