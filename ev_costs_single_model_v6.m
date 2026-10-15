
function results = ev_costs_single_model_v6(sites, priceLib, varargin)
% EV_COSTS_SINGLE_MODEL_V6  Deterministisches Kostenmodell mit Offsets PRO QUERUNG.
%  - Einheiten: €/m, €/Stk., €/MW (Engineering), €/kW (BKZ)
%  - Hindernisse: (Offset * Anzahl_Querungen) + €/m * Länge
%       * Autobahn:   offset=20.000 €, per_m=200 €/m
%       * Gewässer:   offset=50.000 €, per_m=300 €/m
%       * Straße:     offset=10.000 €, per_m=180 €/m
%  - Felder: .N_auto, .N_gewaesser, .N_strasse (Anzahl Querungen). Falls nicht gesetzt:
%       * N_x = (L_x > 0)  (d. h. 1 wenn Länge>0, sonst 0)  [Rückwärtskompatibilität]
%  - N-1 ab 7.5 MW; Double-Feed ab 8 MW
%  - KEINE P50/P90
%
% Aufruf:
%   R = ev_costs_single_model_v6();                                     % Defaults
%   R = ev_costs_single_model_v6(mySites, myPrices);                    % eigene Sites & Preise
%   R = ev_costs_single_model_v6(mySites, myPrices,'writeExcel',true);  % Excel je Site

p = inputParser;
addParameter(p,'writeExcel',false);
addParameter(p,'verbose',true);
parse(p,varargin{:});
writeExcel = p.Results.writeExcel;
verbose    = p.Results.verbose;

if nargin<1||isempty(sites),    sites    = defaultSites();    end
if nargin<2||isempty(priceLib), priceLib = defaultPriceLib(); end

%% Regeln
rules.min_circuits_default     = 2;
rules.max_circuits             = 4;
rules.cores_per_circuit        = 3;
rules.drum_len_m               = 500;
rules.small_max_kW             = 2000;
rules.n1_threshold_kW          = 7500;
rules.double_feed_threshold_kW = 8000;

voltage_levels = [10 20 30];
voltage_factor = [1.00 1.08 1.15];

% Kabelbibliothek: {name, Izul[A], €/m}
cable_lib = { ...
    '1x240 Al', 300, 12.72; ... % statt 22.00 vorher
    '1x400 Al', 400, 19.16; ...
    '1x630 Al', 570, 27.46  ... % statt 40.00 vorher
};

% Ergebnis-Template
template = struct('name',string(''),'kW',0,'MS_kV',0,'cable',string(''), ...
    'circuits',0,'n_trafos',0,'n_fields',0, ...
    'A',0,'B',0,'C',0,'D',0, ...
    'Total_noBKZ',0,'Total_withBKZ',0, ...
    'EUR_per_kW_noBKZ',0,'EUR_per_kW_withBKZ',0);
results = repmat(template, numel(sites), 1);

for s = 1:numel(sites)
    S = sites(s);
    % Längen
    L_hdd = S.L_auto_m + S.L_gewaesser_m + S.L_strasse_m;
    L_reg = max(0, S.route_m - L_hdd);

    % Querungsanzahlen (Fallback: 1 wenn Länge>0, sonst 0)
    if ~isfield(S,'N_auto') || isempty(S.N_auto),           N_auto = double(S.L_auto_m>0); else, N_auto = S.N_auto; end
    if ~isfield(S,'N_gewaesser') || isempty(S.N_gewaesser), N_gewa = double(S.L_gewaesser_m>0); else, N_gewa = S.N_gewaesser; end
    if ~isfield(S,'N_strasse') || isempty(S.N_strasse),     N_str  = double(S.L_strasse_m>0); else, N_str  = S.N_strasse; end

    % Double-Feed
    if isfield(S,'double_feed') && ~isempty(S.double_feed)
        double_feed = logical(S.double_feed);
    else
        double_feed = (S.kW >= rules.double_feed_threshold_kW);
    end

    % Spannung
    if isfield(S,'force_voltage_kV') && ~isempty(S.force_voltage_kV) && any(ismember(S.force_voltage_kV, voltage_levels))
        U_kV = S.force_voltage_kV;
    else
        U_kV = pick_voltage(S.kW, voltage_levels, cable_lib, rules);
    end
    vfac = voltage_factor( find(voltage_levels==U_kV,1,'first') );

    % Kabel + Kreise
    [cable, nCircuits] = pick_cable_and_circuits(S.kW, U_kV, cable_lib, rules);

    % Transformatoren
    n1_required = (S.kW >= rules.n1_threshold_kW);
    if n1_required
        trafo_set = pick_transformers_n1(S.kW, priceLib.trafo_lib, 1.0, 2);
    else
        trafo_set = pick_transformers_simple(S.kW, priceLib.trafo_lib);
    end
    n_trafos = numel(trafo_set);

    % Schaltfelder
    n_fields = n_trafos + 3;

    %% Los A
    A_reg  = priceLib.trench.regular_per_m * L_reg;

    A_auto = (S.L_auto_m     > 0) * (priceLib.trench.autobahn.offset  * N_auto + priceLib.trench.autobahn.per_m  * S.L_auto_m);
    A_gew  = (S.L_gewaesser_m> 0) * (priceLib.trench.gewaesser.offset * N_gewa + priceLib.trench.gewaesser.per_m * S.L_gewaesser_m);
    A_str  = (S.L_strasse_m  > 0) * (priceLib.trench.strasse.offset   * N_str  + priceLib.trench.strasse.per_m   * S.L_strasse_m);

    % Schutzrohr (je Kreis auf HDD-Längen)
    A_rohr  = priceLib.material.schutzrohr_per_m * L_hdd * nCircuits;

    % MS-Kabel (Material) – Leiterlänge = route × Kreise × 3
    A_cable = (cable.price * vfac) * (S.route_m * nCircuits * rules.cores_per_circuit);

    % Muffen/Enden (500 m Trommeln)
    segments = ceil(S.route_m / rules.drum_len_m);
    joints_single = max(0, segments - 1);
    n_joints = joints_single * rules.cores_per_circuit * nCircuits;
    n_ends   = nCircuits * rules.cores_per_circuit * 2;
    A_muffen = priceLib.material.ms_joint_per_pc * n_joints;
    A_end    = priceLib.material.ms_end_per_pc  * n_ends;

    costA = A_reg + A_auto + A_gew + A_str + A_rohr + A_cable + A_muffen + A_end;

    %% Los B
    B_switch = priceLib.station.per_station_base + priceLib.station.per_field * n_fields;
    B_trafos = sum([trafo_set.price]);
    extra    = max(0, n_trafos - 2);
    B_nshv   = priceLib.nshv.base_2trafos + priceLib.nshv.per_extra_trafo * extra;
    B_earth  = priceLib.station.earthing;
    B_tests  = priceLib.station.testing;
    B_eng    = priceLib.station.engineering_per_MW * (S.kW/1000);
    B_house  = priceLib.station.ehouse;

    costB = B_switch + B_trafos + B_nshv + B_earth + B_tests + B_house + B_eng;

    %% Los C
    n_dso = 1 + double(double_feed);
    costC = priceLib.dso.abgang_per_field * n_dso;

    %% Los D
    costD = priceLib.dso.bkz_per_kw * S.kW;

    %% Summen
    total_noBKZ   = costA + costB + costC;
    total_withBKZ = total_noBKZ + costD;

    % Ergebnisfelder
    results(s).name = string(S.name);
    results(s).kW = S.kW;
    results(s).MS_kV = U_kV;
    results(s).cable = string(cable.name);
    results(s).circuits = nCircuits;
    results(s).n_trafos = n_trafos;
    results(s).n_fields = n_fields;
    results(s).A = costA;
    results(s).B = costB;
    results(s).C = costC;
    results(s).D = costD;
    results(s).Total_noBKZ = total_noBKZ;
    results(s).Total_withBKZ = total_withBKZ;
    results(s).EUR_per_kW_noBKZ = total_noBKZ / S.kW;
    results(s).EUR_per_kW_withBKZ = total_withBKZ / S.kW;

    if verbose
        fprintf('[%s | %d kW] TOTAL inkl. BKZ: %0.0f €  |  %0.1f €/kW\n', ...
            results(s).name, results(s).kW, results(s).Total_withBKZ, results(s).EUR_per_kW_withBKZ);
    end

    if writeExcel
        fname = sprintf('%s_%dkW_SINGLE.xlsx', S.name, S.kW);
        T = table();
        T.Position   = ["Trasse (regulär)"; "Autobahn-Querungen"; "Gewässer-Querungen"; "Straßen-Querungen"; ...
                         "Schutzrohre HDD"; "MS-Kabel (Material)"; "MS-Gerademuffen"; "MS-Endverschlüsse"; ...
                         "Schaltanlage (Base + Felder)"; "Transformatoren"; "NS-HV & Busducts"; "Erdungs-/Blitzschutz"; "Prüfungen & Inbetriebnahme"; "E-House / HVAC"; "Engineering (€/MW)"; ...
                         "DSO Abgangsfeld(er)"; "BKZ (MS)"];
        T.Kosten_EUR = [A_reg; A_auto; A_gew; A_str; A_rohr; A_cable; A_muffen; A_end; ...
                        B_switch; B_trafos; B_nshv; B_earth; B_tests; B_house; B_eng; ...
                        costC; costD];
        writetable(T, fname, 'Sheet', 'Kostenpositionen');
        S2 = table(["A";"B";"C";"D";"Total ohne BKZ";"Total inkl. BKZ"], [costA;costB;costC;costD;total_noBKZ;total_withBKZ], ...
            'VariableNames', {'Los','EUR'});
        writetable(S2, fname, 'Sheet', 'Summen');
    end
end
end

%% ==== Defaults (Sites & Preise) ====
function s = defaultSites()
s(1) = site('GoldeneBremm_Sued',        8000,  6066,   0,  90,  45,  0, 1, 6);
s(2) = site('TecklenburgerLand_West',   8000,  4288,   0,   0,  15,  0, 0, 3);
s(3) = site('Hochwald_West',            8000,  6055,   0,   0,  15,  0, 0, 2);
s(4) = site('Inntal_West',              8000, 13322,   0,  20,  75,  0, 1, 15);
end

function x = site(name, kW, route_m, L_auto, L_gewaesser, L_strasse, N_auto, N_gewaesser, N_strasse)
x = struct('name',string(name), 'kW',kW, 'route_m',route_m, ...
           'L_auto_m',L_auto, 'L_gewaesser_m',L_gewaesser, 'L_strasse_m',L_strasse, ...
           'N_auto',N_auto, 'N_gewaesser',N_gewaesser, 'N_strasse',N_strasse, ...
           'double_feed', [], 'force_voltage_kV', []);
end

function P = defaultPriceLib()
P.trench.regular_per_m = 200;
P.trench.autobahn.offset  = 20000; P.trench.autobahn.per_m  = 200;
P.trench.gewaesser.offset = 50000; P.trench.gewaesser.per_m = 300;
P.trench.strasse.offset   = 10000; P.trench.strasse.per_m   = 180;

P.material.schutzrohr_per_m = 46.30;
P.material.ms_joint_per_pc  = 289.91;
P.material.ms_end_per_pc    = 162.39;

P.station.per_station_base     = 50000;
P.station.per_field            = 20000;
P.station.earthing             = 50000;
P.station.testing              = 45000;
P.station.engineering_per_MW   = 15000;
P.station.ehouse               = 300000;

P.trafo_lib = [ ...
    struct('S',4.0, 'price',230000); ...
    struct('S',6.3, 'price',350000); ...
    struct('S',10.0,'price',500000) ...
];

P.nshv.base_2trafos     = 200000;
P.nshv.per_extra_trafo  = 0;

P.dso.abgang_per_field  = 120000;
P.dso.bkz_per_kw        = 110;
end

%% ==== Auswahlfunktionen ====
function U_kV = pick_voltage(total_kW, levels, cable_lib, rules)
bestCost = inf; U_kV = levels(1);
for u = levels
    [cb, nc] = pick_cable_and_circuits(total_kW, u, cable_lib, rules);
    cscore = cb.price * nc;
    if cscore < bestCost, bestCost = cscore; U_kV = u; end
end
if total_kW/1000 > 25 && U_kV < 30, U_kV = 30; end
end

function [cable, nCircuits] = pick_cable_and_circuits(total_kW, U_kV, cable_lib, rules)
I_total = (total_kW*1e3)/(sqrt(3)*U_kV*1e3);
minc = (total_kW <= rules.small_max_kW) * 1 + (total_kW > rules.small_max_kW) * rules.min_circuits_default;
best.cost = inf; best.idx = []; best.nCircuits = [];
for i = 1:size(cable_lib,1)
    Iz = cable_lib{i,2};
    for nc = minc:rules.max_circuits
        if Iz*nc >= I_total
            cscore = cable_lib{i,3} * nc;
            if cscore < best.cost, best.cost = cscore; best.idx = i; best.nCircuits = nc; end
            break
        end
    end
end
if isempty(best.idx), i = size(cable_lib,1); nc = rules.max_circuits;
else,                 i = best.idx;          nc = best.nCircuits;
end
cable.name = cable_lib{i,1}; cable.Izul = cable_lib{i,2}; cable.price = cable_lib{i,3};
nCircuits = nc;
end

function trafo_set = pick_transformers_simple(total_kW, trafo_lib)
P = total_kW/1000; cpm = arrayfun(@(t) t.price/t.S, trafo_lib);
[~,ord] = sort(cpm,'ascend'); need = P; chosen = [];
for k = 1:numel(ord)
    t = trafo_lib(ord(k)); n = floor(need/t.S); if need>0 && n==0, n = 1; end
    chosen = [chosen, repmat(t,1,n)]; need = need - n*t.S; if need<=0, break; end
end
if need>0, [~,imax] = max([trafo_lib.S]); chosen = [chosen, trafo_lib(imax)]; end
trafo_set = chosen;
end

function trafo_set = pick_transformers_n1(total_kW, trafo_lib, n1_fraction, min_trafos)
P = total_kW/1000; bestCost = inf; bestSet = []; maxUnits = 8;
for n1 = 0:maxUnits
  for n2 = 0:maxUnits
    for n3 = 0:maxUnits
      if n1+n2+n3==0, continue; end
      set = [repmat(trafo_lib(1),1,n1), repmat(trafo_lib(2),1,n2), repmat(trafo_lib(3),1,n3)];
      if numel(set) < min_trafos, continue; end
      totalS = sum([set.S]); if totalS < P, continue; end
      [~,imax] = max([set.S]); remaining = totalS - set(imax).S;
      if remaining < n1_fraction*P, continue; end
      cost = sum([set.price]); if cost < bestCost, bestCost = cost; bestSet = set; end
    end
  end
end
if isempty(bestSet)
    bestSet = pick_transformers_simple(total_kW, trafo_lib);
    while numel(bestSet) < min_trafos
        [~,imax] = max([trafo_lib.S]); bestSet = [bestSet, trafo_lib(imax)];
    end
end
trafo_set = bestSet;
end
