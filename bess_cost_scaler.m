function out = bess_cost_scaler(p)
% Kostenskalierung für containerisierte BESS
% Inputs: struct p mit Parametern (siehe Defaults unten)
% Output: struct out mit CAPEX-Breakdown, OPEX usw.

% --- Default-Parameter setzen (nur falls nicht übergeben) ---
p = set_default(p, 'E_unit_MWh', 3.0);        % MWh pro Container
p = set_default(p, 'P_unit_MW',  1.5);        % MW pro Container
p = set_default(p, 'n_units',    10);         % Anzahl Container

% Preise/Kosten
p = set_default(p, 'price_DC_per_kWh_base', 70);  % €/kWh (Batterie+Racks+Thermal+BMS)
p = set_default(p, 'pcs_cost_per_kW',       20);  % €/kW (PCS/AC-Seite)
p = set_default(p, 'bos_pct',  0.08);             % Balance of System (Prozente von HW)
p = set_default(p, 'epc_pct',  0.10);             % EPC (Engineering/Procurement/Construction)
p = set_default(p, 'soft_pct', 0.07);             % Planung, Permits, etc.
p = set_default(p, 'site_fixed_cost', 8e4);       % € je Standort (fix)

% Skalierung (Mengenrabatt)
p = set_default(p, 'discount_b', -0.12);          % Exponent für n_units^b
p = set_default(p, 'price_floor_per_kWh', 50);   % €/kWh Boden

% Wirkungsgrade (zur Info/Weiterverwendung)
p = set_default(p, 'eta_DC_DC', 0.95);
p = set_default(p, 'eta_AC_AC', 0.90);

% OPEX
p = set_default(p, 'fixed_opex_pct_per_year', 0.02);


% --- Abgeleitete Größen ---
E_total_MWh = p.E_unit_MWh * p.n_units;
P_total_MW  = p.P_unit_MW  * p.n_units;
E_total_kWh = E_total_MWh * 1e3;

% Mengenrabatt auf DC-BESS-Preis
price_kWh = max(p.price_DC_per_kWh_base * (p.n_units^p.discount_b), p.price_floor_per_kWh);

% Kostenbestandteile
capex_DC   = price_kWh * E_total_kWh;                   % €/kWh * kWh
capex_PCS  = p.pcs_cost_per_kW * (P_total_MW * 1e3);    % €/kW * kW
hw_sum     = capex_DC + capex_PCS;

capex_BOS  = p.bos_pct  * hw_sum;
capex_EPC  = p.epc_pct  * hw_sum;
capex_SOFT = p.soft_pct * hw_sum;

capex_total = hw_sum + capex_BOS + capex_EPC + capex_SOFT + p.site_fixed_cost;

% --- OPEX ---
opex_fixed_pa = p.fixed_opex_pct_per_year * capex_total;

% --- CAPEX pro kWh berechnen ---
capex_total_per_kWh = capex_total / E_total_kWh;

capex_breakdown_per_kWh = struct( ...
    'DC',   capex_DC   / E_total_kWh, ...
    'PCS',  capex_PCS  / E_total_kWh, ...
    'BOS',  capex_BOS  / E_total_kWh, ...
    'EPC',  capex_EPC  / E_total_kWh, ...
    'SOFT', capex_SOFT / E_total_kWh, ...
    'SITE', p.site_fixed_cost / E_total_kWh );


% --- Outputstruktur ---
out = struct();
out.params                   = p;
out.price_kWh                = price_kWh;  % nur DC
out.capex_breakdown          = struct('DC',capex_DC,'PCS',capex_PCS,'BOS',capex_BOS,'EPC',capex_EPC,'SOFT',capex_SOFT,'SITE',p.site_fixed_cost);
out.capex_breakdown_per_kWh  = capex_breakdown_per_kWh;
out.capex_total              = capex_total;
out.capex_total_per_kWh      = capex_total_per_kWh;
out.opex_fixed_pa            = opex_fixed_pa;
out.E_total_MWh              = E_total_MWh;
out.P_total_MW               = P_total_MW;
out.eta_DC_DC                = p.eta_DC_DC;
out.eta_AC_AC                = p.eta_AC_AC;

end


% ---- lokale Hilfsfunktion ----
function p = set_default(p, field, val)
if ~isfield(p, field) || isempty(p.(field))
    p.(field) = val;
end
end
