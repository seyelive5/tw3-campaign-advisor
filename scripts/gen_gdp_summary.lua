--[[ 건물 GDP 사전합산 생성기 (LuaJIT로 실행) ============================
  왜 존재하나(v73): 런타임에 fx 표를 순회하며 string.find를 돌리는 것이
  WH3 패치 Lua를 오염시킴이 실측됐다(핫리로드 단계 격리 — 리터럴 find
  20만 회 단독으로 root 메서드가 함수를 반환하는 오염 재현). 그래서
  fx_gdp의 분류 규칙을 '여기서' 실행해 결과만 작은 표로 굽는다.
  규칙은 advisor_bld.lua의 fx_gdp(하니스 폴백 경로)와 반드시 동일해야
  하며, 하니스 §0d가 그 폴백을 계속 검증한다.
  실행: luajit scripts/gen_gdp_summary.lua
=========================================================================]]

local ROOT = arg[0]:match("^(.*)[/\\]scripts[/\\]") or "."
dofile(ROOT .. "/src/script/campaign/mod/advisor_db_building_fx.lua")
assert(type(CA_BLD_FX) == "table", "CA_BLD_FX 로드 실패")

-- advisor_bld.lua fx_gdp와 동일한 분류 규칙
local function classify(rows)
	local flat, pct, skipped = 0, 0, 0
	for _, r in ipairs(rows) do
		local e, s = r.e or "", r.s or ""
		if e:find("economy_gdp", 1, true)
			and (s == "this_building" or s:find("own", 1, true))
			and not s:find("force", 1, true) then
			if not e:find("_mod", 1, true) then
				flat = flat + (tonumber(r.v) or 0)
			elseif e:find("gdp_mod_all", 1, true) then
				pct = pct + (tonumber(r.v) or 0)
			else
				skipped = skipped + 1
			end
		end
	end
	return flat, pct, skipped
end

local keys = {}
for k in pairs(CA_BLD_FX) do keys[#keys + 1] = k end
table.sort(keys)

local out, kept = {}, 0
out[#out + 1] = "--[[ ========================================================================="
out[#out + 1] = "  TW3 어드바이저 — 건물 GDP 사전합산 (생성 · 손대지 말 것)"
out[#out + 1] = "  ---------------------------------------------------------------------------"
out[#out + 1] = "  생성기: scripts/gen_gdp_summary.lua   원본: advisor_db_building_fx.lua"
out[#out + 1] = "  v73: 런타임 fx 순회+string.find가 WH3 패치 Lua를 오염시키는 실측"
out[#out + 1] = "  (핫리로드 단계 격리 — 리터럴 find 20만 회 단독 재현)에 따라 합산을"
out[#out + 1] = "  생성 시점으로 옮겼다. 인게임 경로는 이 표의 조회뿐(find 0회)."
out[#out + 1] = "    CA_BLD_GDP[레벨키] = { f=정액GDP/턴, p=gdp_mod_all%, s=보수제외건수 }"
out[#out + 1] = "    셋 다 0인 키는 생략 — 없는 키 = 0 취급(fx_gdp 폴백과 동일 의미)."
out[#out + 1] = "============================================================================]]"
out[#out + 1] = "CA_BLD_GDP = CA_BLD_GDP or {}"
out[#out + 1] = "local G = CA_BLD_GDP"

for _, k in ipairs(keys) do
	local f, p, s = classify(CA_BLD_FX[k])
	if f ~= 0 or p ~= 0 or s ~= 0 then
		kept = kept + 1
		local parts = {}
		if f ~= 0 then parts[#parts + 1] = "f=" .. f end
		if p ~= 0 then parts[#parts + 1] = "p=" .. p end
		if s ~= 0 then parts[#parts + 1] = "s=" .. s end
		out[#out + 1] = string.format("G[%q]={%s}", k, table.concat(parts, ","))
	end
end

local path = ROOT .. "/src/script/campaign/mod/advisor_db_building_gdp.lua"
local fh = assert(io.open(path, "wb"))
fh:write(table.concat(out, "\n"), "\n")
fh:close()

-- 자기검증: 알려진 실값 + 전 키 재대조
dofile(path)
local function G_of(k)
	local d = CA_BLD_GDP[k]
	return d and (d.f or 0) or 0, d and (d.p or 0) or 0, d and (d.s or 0) or 0
end
local bad = 0
for _, k in ipairs(keys) do
	local f, p, s = classify(CA_BLD_FX[k])
	local gf, gp, gs = G_of(k)
	if f ~= gf or p ~= gp or s ~= gs then bad = bad + 1 end
end
local f1 = select(1, G_of("wh_main_emp_industry_basic_1"))
local f2 = select(1, G_of("wh2_main_emp_resource_gemstones_1"))
print(string.format("생성 완료: 전체 %d키 중 %d키 기록 · 재대조 불일치 %d · 직물공장=%s 보석갱도=%s",
	#keys, kept, bad, tostring(f1), tostring(f2)))
assert(bad == 0, "재대조 불일치")
assert(f1 == 250 and f2 == 200, "알려진 실값 불일치")
