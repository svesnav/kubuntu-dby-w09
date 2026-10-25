-- MatePad 11 speakers and microphones.
-- Speakers: the UCM "Speaker" device is 4 channels (4 TDM slots), but the
-- four amps only ever play slot 0 or 1: matepad-smartpa points the two
-- speakers on the viewer's left at slot 0 and the two on the right at slot 1,
-- following the screen orientation. So the sink is stereo for PipeWire:
-- slots 2/3 are AUX0/AUX1, which nothing is mixed into. Mono (e.g. the
-- Plasma volume click) goes to FL+FR and so to all four speakers; surround
-- is downmixed to FL/FR. (With FL,FR,RL,RR, mono reached only the FL/FR amps.)
-- Only PCM 0: PCM 1 is the HDMI/DisplayPort output (USB-C monitor).
-- Headroom: the q6 PCM only moves its pointer once per period (1024 frames)
-- and only hands complete periods to the DSP, but ALSA does not flag it as a
-- batch device, so PipeWire ran it with headroom 0. Whenever a client asked
-- for less than ~21 ms (graph quantum <= 512: Firefox's extra streams, paplay,
-- notification sounds) the DSP got no full period, the pointer stopped and
-- the sound clicked or dropped out, mostly without an xrun in pw-top. 1024
-- covered quantum 512 only; 2048 keeps the DSP fed down to quantum 64 and
-- while the quantum changes (tested 2026-10-21). Costs ~43 ms of latency.
-- No pause while idle: PipeWire's pause is a q6 ASM PAUSE, which keeps the
-- periods already queued in the DSP and plays them on resume (a click with
-- an echo of the old audio after each jump in a video); the sink plays
-- silence instead until WirePlumber suspends (closes) it after 5 s idle,
-- which still switches the amps off.
table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "node.name", "matches", "alsa_output.*konaqrdsndcard_0__sink" },
    },
  },
  apply_properties = {
    ["audio.position"] = "FL,FR,AUX0,AUX1",
    ["api.alsa.headroom"] = 2048,
    ["node.pause-on-idle"] = false,
  },
})

-- Microphones: the UCM "Mic" device is 4 channels in Huawei's speaker-mic
-- order. A tap test showed channel 1 is the rear mic (next to the camera);
-- 0, 2 and 3 are the three mics on the top edge. Label them so a stereo or
-- mono capture mixes the rear mic evenly instead of putting it on one side
-- (the left/right order of the top three is a guess).
table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "node.name", "matches", "alsa_input.*kona*" },
    },
  },
  apply_properties = {
    ["audio.position"] = "FL,RC,FC,FR",
  },
})
