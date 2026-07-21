--[[===========================================================================
  TW3 캠페인 어드바이저 — Phase 1 / Step 2 (v2: 콘솔 불필요 버전)
  ---------------------------------------------------------------------------
  목적 : 이 스크립트가 "캠페인 시작 시 자동 로드"되는지 증명한다.
  범위 : 읽기 전용. 게임 상태를 바꾸는 행동은 전혀 하지 않는다.
  증거 : 3중으로 남긴다(각각 pcall 보호 — 하나 실패해도 나머지 진행).
         (1) out()  → Lua 콘솔/스크립트 로그 (있을 때만 보임)
         (2) 증거 .txt 파일 직접 기록 → 콘솔 없어도 파일만 열면 확인.
             동시에 io.open 가용 여부(프리플라이트)까지 자동 판정된다.
         (3) first tick 시 campaign_manager 로 로컬 팩션명 확인.
  로드 : 바닐라 lib_mod_loader.lua 가 script\campaign\mod\*.lua 를 자동 실행.
=============================================================================]]

-- 증거 파일 경로(절대경로 — 게임 작업폴더 불확실성 회피). 사용자 프로필 루트에 생성.
local PROOF_PATH = "C:/Users/veria/tw3_advisor_proof.txt"

-- out() + (io 가능하면) 파일 기록. io 가 샌드박스에서 제거됐을 수 있어 pcall 보호.
local function proof(msg, append)
	out("[CAMPAIGN_ADVISOR] " .. msg)
	pcall(function()
		if io and io.open then
			local f = io.open(PROOF_PATH, append and "a" or "w")
			if f then f:write(msg .. "\n"); f:close() end
		end
	end)
end

-- [1] top-level 실행 증거 (파일 새로 생성). io.open 가용 여부도 함께 기록.
proof("STEP2 top-level 실행됨. io.open = " .. tostring(io and io.open), false)

-- [2] 캠페인 컨텍스트 증거 — first tick 시점에 campaign_manager 사용 가능 확인
local cm = get_campaign_manager()
cm:add_first_tick_callback(
	function()
		local ok, faction_name = pcall(function() return cm:get_local_faction_name() end)
		proof("STEP2 first tick 도달. 로컬 팩션 = " .. tostring(ok and faction_name or "(조회 실패)"), true)
	end
)
