-- ModuleScript: Animations
-- Every tween in the menu lives here. UI calls these, nothing else touches TweenService
-- (Functionality's toasts go through Animations.tween too).
-- Flip Animations.Enabled = false for instant (reduced-motion) transitions.

local TweenService = game:GetService("TweenService")

local Animations = {}
Animations.Enabled = true

local INFOS = {
	ease = TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	fast = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	instant = TweenInfo.new(0),
}

function Animations.tween(obj, kind, props)
	local info = if Animations.Enabled then INFOS[kind] else INFOS.instant
	local t = TweenService:Create(obj, info, props)
	t:Play()
	return t
end

-- row visuals ---------------------------------------------------------

function Animations.setSwitch(row, animate, colors)
	local kind = animate and "fast" or "instant"
	Animations.tween(row.knob, kind, { Position = UDim2.new(0, row.on and 19 or 3, 0.5, 0) })
	Animations.tween(row.track, kind, { BackgroundColor3 = row.on and colors.accent or colors.line })
	if row.bar then
		Animations.tween(row.bar, kind, { BackgroundTransparency = row.on and 0 or 1 })
	end
end

function Animations.highlightRow(row, on)
	Animations.tween(row.stroke, "fast", { Transparency = on and 0 or 1 })
end

-- tabs ----------------------------------------------------------------

function Animations.styleTab(button, active, colors)
	Animations.tween(button, "fast", {
		BackgroundTransparency = active and 0 or 1,
		TextColor3 = active and colors.text or colors.muted,
	})
end

function Animations.showPanel(panel, restPos)
	panel.GroupTransparency = 1
	panel.Position = restPos + UDim2.fromOffset(0, 5)
	panel.Visible = true
	Animations.tween(panel, "ease", { GroupTransparency = 0, Position = restPos })
end

-- minimize / expand ---------------------------------------------------
-- refs = { root, body, barGroup, sub, lead }

function Animations.collapse(refs, size, leadPos)
	local rootTween = Animations.tween(refs.root, "ease", { Size = UDim2.fromOffset(size.X, size.Y) })
	Animations.tween(refs.body, "ease", { GroupTransparency = 1 })
	Animations.tween(refs.barGroup, "ease", { GroupTransparency = 1 })
	Animations.tween(refs.sub, "fast", { TextTransparency = 1 })
	Animations.tween(refs.lead, "ease", { Position = leadPos })
	return rootTween
end

function Animations.expand(refs, size, leadPos)
	local rootTween = Animations.tween(refs.root, "ease", { Size = UDim2.fromOffset(size.X, size.Y) })
	Animations.tween(refs.body, "ease", { GroupTransparency = 0 })
	Animations.tween(refs.barGroup, "ease", { GroupTransparency = 0 })
	Animations.tween(refs.sub, "ease", { TextTransparency = 0 })
	Animations.tween(refs.lead, "ease", { Position = leadPos })
	return rootTween
end

-- status dot ----------------------------------------------------------
-- red while the menu is closed (pill), green while it is open, with a pulsing ring when open.

local pulses = setmetatable({}, { __mode = "k" })

function Animations.setStatus(dot, open, colors)
	Animations.tween(dot, "fast", { BackgroundColor3 = open and colors.good or colors.bad })
end

function Animations.stopPulse(ring, stroke)
	local p = pulses[ring]
	if p then
		p[1]:Cancel()
		p[2]:Cancel()
		pulses[ring] = nil
	end
	ring.Size = UDim2.fromOffset(10, 10)
	stroke.Transparency = 1
end

function Animations.startPulse(ring, stroke, color)
	Animations.stopPulse(ring, stroke)
	stroke.Color = color
	if not Animations.Enabled then
		stroke.Transparency = 0.55 -- static halo for reduced motion
		return
	end
	stroke.Transparency = 0.15
	local info = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1)
	local grow = TweenService:Create(ring, info, { Size = UDim2.fromOffset(26, 26) })
	local fade = TweenService:Create(stroke, info, { Transparency = 1 })
	pulses[ring] = { grow, fade }
	grow:Play()
	fade:Play()
end

-- slider popover ------------------------------------------------------

function Animations.popOpen(pop, x, y)
	pop.Position = UDim2.fromOffset(x, y + 5)
	pop.GroupTransparency = 1
	pop.Visible = true
	return Animations.tween(pop, "fast", { GroupTransparency = 0, Position = UDim2.fromOffset(x, y) })
end

function Animations.popClose(pop)
	return Animations.tween(pop, "fast", { GroupTransparency = 1 })
end

function Animations.knobGrow(knob, big)
	local s = big and 20 or 16
	Animations.tween(knob, "fast", { Size = UDim2.fromOffset(s, s) })
end

-- countdown bar -------------------------------------------------------
-- refill eases back in after a reset, drain tracks the clock exactly.

function Animations.stepBar(shown, target, dt)
	if shown < target then
		if not Animations.Enabled then
			return target
		end
		return shown + (target - shown) * (1 - math.exp(-dt / 0.05))
	end
	return target
end

return Animations
