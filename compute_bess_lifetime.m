function lifetime = compute_bess_lifetime(E_kWh, cycles_throughput)
% COMPUTE_BESS_LIFETIME  Ermittelt die Lebensdauer eines containerbasierten
% Batteriesystems auf Basis der Zielkapazität und der Vollzyklenzahl pro
% Jahr.  Dieses Skript spiegelt die Logik aus ``run_bess_target.m`` wider
% und stellt sicher, dass dieselben Containergrößen (5.64 MWh, 4 h) sowie
% die gleichen Kostenskalierungs- und Degradationsannahmen genutzt werden.
%
% Inputs
%   E_kWh             – nominelle Batteriegröße der besten Lösung [kWh]
%   cycles_throughput – Vollzyklen pro Jahr (Energie-Throughput‑Definition)
%
% Output
%   lifetime – Struktur mit Ergebnissen der Kostenskalierung (res),
%              Degradationsanalyse (deg) und Metadaten wie n_units,
%              E_total_MWh, P_total_MW sowie replacement_year

    % Zielkapazität in MWh
    E_target_MWh = E_kWh / 1000;
    % Vollzyklen pro Jahr (Throughput)
    efc_per_year = cycles_throughput;

    % Fixe Geräteeigenschaften (CATL EnerX, 20‑ft Container)
    E_unit_MWh = 5.64;
    P_unit_MW  = E_unit_MWh / 4;  % 4‑Stunden‑System

    % Benötigte Containeranzahl
    n_units = max(1, ceil(E_target_MWh / E_unit_MWh));

    % Parameterstruktur für bess_cost_scaler (Standardannahmen)
    p = struct();
    p.E_unit_MWh = E_unit_MWh;
    p.P_unit_MW  = P_unit_MW;
    p.n_units    = n_units;
    % Hardware‑Preise und Aufschläge (konsistent mit run_bess_target)
    p.price_DC_per_kWh_base = 70;
    p.pcs_cost_per_kW       = 20;
    p.bos_pct  = 0.08;
    p.epc_pct  = 0.10;
    p.soft_pct = 0.07;
    p.site_fixed_cost = 8e4;
    % Mengenrabatt und Preisboden
    p.discount_b = -0.12;
    p.price_floor_per_kWh = 50;
    % Wirkungsgrade (zur Info)
    p.eta_DC_DC = 0.95;
    p.eta_AC_AC = 0.90;
    % OPEX
    p.fixed_opex_pct_per_year = 0.02;
    p.var_opex_per_MWh_throughput = 1.5;  % wird hier nicht verwendet

    % Kosten berechnen
    res = bess_cost_scaler(p);

    % Degradation berechnen (Konstanten identisch zu run_bess_target)
    deg = bess_degradation(struct('efc_per_year', efc_per_year, ...
                                  'calendar_fade_per_year', 0.00617, ...
                                  'cycle_fade_per_EFC', 4.09e-6, ...
                                  'EoL_frac', 0.80), 30);

    % Ergebnisse zusammenstellen
    lifetime = struct();
    lifetime.n_units           = n_units;
    lifetime.E_total_MWh       = res.E_total_MWh;
    lifetime.P_total_MW        = res.P_total_MW;
    lifetime.replacement_year  = deg.replacement_year;
    lifetime.res               = res;
    lifetime.deg               = deg;
end