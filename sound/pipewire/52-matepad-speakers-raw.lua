-- The hardware speaker sink is fed by the "Speakers" filter chain
-- (/etc/pipewire/pipewire.conf.d/60-matepad-speaker-eq.conf: high-pass and
-- limiter, against distortion). Keep the unfiltered sink selectable, but
-- below the filter chain, so the filtered one is the default output.
-- Only PCM 0: PCM 1 is the HDMI/DisplayPort output (USB-C monitor).
table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "node.name", "matches", "alsa_output.*konaqrdsndcard_0__sink" },
    },
  },
  apply_properties = {
    ["priority.session"] = 100,
    ["priority.driver"] = 100,
    ["node.description"] = "Speakers (unfiltered)",
  },
})
