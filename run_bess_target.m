%% run_bess_target.m — Zielkapazität vorgeben, Einheiten automatisch berechnen (CATL EnerX 5.64 MWh)

% === Eingaben vom Team ===
E_target_MWh = Current_Battery_kWh/1000;   % Ziel-Gesamtkapazität am Standort (MWh) -> HIER parametrieren
efc_per_year  = Current_FullCycles_Throughput;      % Vollzyklen pro Jahr -> HIER parametrieren

% === Fixe Geräteeigenschaften (CATL EnerX, 20-ft) ===
E_unit_MWh = 5.64;            % MWh je Container (fix)
P_unit_MW  = E_unit_MWh/4;    % 4h-System -> ~1.41 MW je Container

% === Anzahl Container bestimmen ===
n_units = ceil(E_target_MWh / E_unit_MWh);

% === Parameterstruktur für Kosten (Baseline gleich wie zuvor) ===
p = struct();
p.E_unit_MWh = E_unit_MWh;
p.P_unit_MW  = P_unit_MW;
p.n_units    = n_units;

% Kosten/Skalierung (Standardannahmen; bei Bedarf ändern)
p.price_DC_per_kWh_base = 70;   % Basispreis DC-Hardware €/kWh
p.pcs_cost_per_kW       = 20;   % €/kW (PCS)
p.bos_pct  = 0.08;
p.epc_pct  = 0.10;
p.soft_pct = 0.07;
p.site_fixed_cost = 8e4;         % €

p.discount_b = -0.12;            % Mengenrabatt-Exponent
p.price_floor_per_kWh = 50;     % €/kWh Untergrenze

% Wirkungsgrade (Info)
p.eta_DC_DC = 0.95;
p.eta_AC_AC = 0.90;

% OPEX
p.fixed_opex_pct_per_year      = 0.02;
p.var_opex_per_MWh_throughput  = 1.5;   % optional (wird hier nicht verwendet)

% === Kosten berechnen ===
res = bess_cost_scaler(p);

% === Degradation berechnen (mit efc_per_year aus der Standortübergabe) ===
deg = bess_degradation(struct('efc_per_year', efc_per_year, ...
                              'calendar_fade_per_year', 0.00617, ...
                              'cycle_fade_per_EFC', 4.09e-6, ...
                              'EoL_frac', 0.80 ), 30);

% === Zusammenfassung ausgeben ===
fprintf('\n=== EnerX-Auslegung (Zieleingabe) ===\n');
fprintf('Zielkapazität: %.1f MWh\n', E_target_MWh);
fprintf('Einheit: EnerX 5.64 MWh (4h -> %.2f MW)\n', P_unit_MW);
fprintf('Benötigte Container: %d\n', n_units);
fprintf('Erreichte Gesamtkapazität: %.1f MWh (Überbau: +%.1f %%)\n', res.E_total_MWh, (res.E_total_MWh/E_target_MWh - 1)*100);
fprintf('Gesamtleistung: %.1f MW\n', res.P_total_MW);

fprintf('Skalierter DC-Preis: %.1f €/kWh (nur DC)\n', res.price_kWh);

disp('CAPEX Breakdown (€):'); 
disp(res.capex_breakdown);

% NEU: CAPEX je kWh gesamt + Breakdown je kWh
fprintf('CAPEX gesamt: %.0f € (%.1f €/kWh gesamt)\n', res.capex_total, res.capex_total_per_kWh);
disp('CAPEX Breakdown (€/kWh):');
disp(res.capex_breakdown_per_kWh);

fprintf('Fixe OPEX p.a.: %.0f €\n', res.opex_fixed_pa);
fprintf('Ersatzjahr (bei %.0f %% EoL): %s\n', 100*deg.params.EoL_frac, string(deg.replacement_year));

% === Plot der Degradation ===
figure;
plot(0:30, 100*deg.cap_frac_by_year, 'LineWidth', 1.5);
xlabel('Jahre'); ylabel('Restkapazität [%]'); grid on;
title('BESS-Kapazität über die Zeit (EnerX, Standortzyklen)');

% === CAPEX vs. Zielkapazität plotten (z. B. 10–200 MWh in 1-MWh-Schritten) ===
out_capex_sweep = plot_cost_vs_capacity(p, 10, 200, 1);
