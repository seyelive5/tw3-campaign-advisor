--[[===========================================================================
  TW3 캠페인 어드바이저 — Phase 1 / Step 2 (v3: 로더 계약 준수)
  ---------------------------------------------------------------------------
  로더(lib_mod_loader.lua) 실측 계약:
    1) NewSession 때 script\campaign\mod\*.lua 를 로드(top-level 실행).
    2) first tick 때 core:execute_mods 가 "파일명과 동일한 전역 함수"를 호출.
  ⇒ 실제 로직은 전역 함수 campaign_advisor() 안에. 그 안에서 cm/core 는 전역.
     (top-level 에서 get_campaign_manager() 부르면 nil → 조용히 죽음. v2 버그였음.)
  범위 : 읽기 전용. 상태 변경 없음.
=============================================================================]]

local PROOF_PATH = "C:/Users/veria/tw3_advisor_proof.txt"

-- out() + (io 가능하면) 파일 기록. 둘 다 pcall 보호.
local function proof(msg, append)
	pcall(function() out("[CAMPAIGN_ADVISOR] " .. msg) end)
	pcall(function()
		if io and io.open then
			local f = io.open(PROOF_PATH, append and "a" or "w")
			if f then f:write(msg .. "\n"); f:close() end
		end
	end)
end

-- [1] NewSession/로드 증거 (top-level). 파일 새로 생성.
proof("STEP2 파일 로드됨 (NewSession/top-level). io.open = " .. tostring(io and io.open), false)

-- [2] 로더가 first tick 때 호출하는, 파일명과 동일한 전역 함수.
--     이 시점엔 cm/core 가 전역으로 완전히 준비돼 있음.
function campaign_advisor()
	local ok, faction_name = pcall(function() return cm:get_local_faction_name() end)
	proof("STEP2 campaign_advisor() 실행됨 (first tick / execute_mods). 로컬 팩션 = "
		.. tostring(ok and faction_name or "(조회 실패)"), true)
end
