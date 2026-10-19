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
	snap = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), -- button presses
	back = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), -- springy settle
	linear = TweenInfo.new(0.25, Enum.EasingStyle.Linear), -- progress bar, matches its 0.25 s update
}

function Animations.tween(obj, kind, props)
	local info = if Animations.Enabled then INFOS[kind] else INFOS.instant
	local t = TweenService:Create(obj, info, props)
	t:Play()
	return t
end

-- sets properties at once AND cancels any tween still running on them (a plain assignment would be overwritten
-- by the next frame of a tween that is in flight, which is what left the menu at a stale size)
function Animations.snap(obj, props)
	for k, v in pairs(props) do
		obj[k] = v
	end
	return Animations.tween(obj, "instant", props)
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

function Animations.styleTab(button, active, colors, surfaceT)
	Animations.tween(button, "fast", {
		BackgroundTransparency = active and (surfaceT or 0) or 1,
		TextColor3 = active and colors.text or colors.muted,
	})
end

-- tab switch: the new panel slides in from `dx` pixels away while the old one slides out the other way.
-- dx > 0 means the new panel comes from the right (moving to a tab further right).
function Animations.slideIn(panel, restPos, dx)
	panel.GroupTransparency = 1
	panel.Position = restPos + UDim2.fromOffset(dx, 0)
	panel.Visible = true
	return Animations.tween(panel, "ease", { GroupTransparency = 0, Position = restPos })
end

function Animations.slideOut(panel, restPos, dx)
	return Animations.tween(panel, "ease", { GroupTransparency = 1, Position = restPos + UDim2.fromOffset(dx, 0) })
end

-- menu height follows the active tab. refs = { root, body }. animate = false snaps (no tween at all).
function Animations.resize(refs, size, animate)
	local goal = UDim2.fromOffset(size.X, size.Y)
	if not animate then
		Animations.snap(refs.root, { Size = goal })
		Animations.snap(refs.body, { Size = goal })
		return
	end
	Animations.tween(refs.body, "ease", { Size = goal })
	return Animations.tween(refs.root, "ease", { Size = goal })
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

-- tab bar carousel ----------------------------------------------------
-- eases the scroll position (in tabs) toward its target; the target is any number, the UI wraps it around the ring
function Animations.stepCarousel(shown, target, dt)
	if not Animations.Enabled then
		return target
	end
	local d = target - shown
	if math.abs(d) < 0.002 then
		return target
	end
	return shown + d * (1 - math.exp(-dt / 0.06))
end

-- small buttons (media controls, tab arrows) ---------------------------

function Animations.hover(btn, on)
	Animations.tween(btn, "fast", { BackgroundTransparency = on and 0.35 or 1 })
end

-- scale = the UIScale inside the button
function Animations.press(scale, down)
	Animations.tween(scale, down and "snap" or "back", { Scale = down and 0.84 or 1 })
end

-- play <-> pause: the icon that leaves shrinks away, the one that arrives pops in
function Animations.swap(hideScale, showScale)
	showScale.Parent.Visible = true
	Animations.snap(showScale, { Scale = 0.3 })
	Animations.tween(showScale, "back", { Scale = 1 })
	local t = Animations.tween(hideScale, "snap", { Scale = 0.01 })
	t.Completed:Once(function()
		if hideScale.Scale < 0.02 then
			hideScale.Parent.Visible = false
		end
	end)
end

-- previous / next: the icon slides a few pixels in its direction and springs back
function Animations.nudge(icon, dx)
	local t = Animations.tween(icon, "snap", { Position = UDim2.new(0.5, dx, 0.5, 0) })
	t.Completed:Once(function()
		Animations.tween(icon, "back", { Position = UDim2.fromScale(0.5, 0.5) })
	end)
end

-- now playing -----------------------------------------------------------

-- new song: the text slides in from the right while fading in
function Animations.textIn(label, rest)
	label.TextTransparency = 1
	label.Position = rest + UDim2.fromOffset(10, 0)
	Animations.tween(label, "ease", { TextTransparency = 0, Position = rest })
end

-- progress bar: glides between the 4 updates per second, jumps when the song changes or is seeked
function Animations.progress(bar, fraction, jump)
	Animations.tween(bar, jump and "instant" or "linear", { Size = UDim2.fromScale(fraction, 1) })
end

-- the status dot + "FMenu" text fade out while a song owns the pill
function Animations.leadVisible(dot, text, visible)
	Animations.tween(dot, "ease", { BackgroundTransparency = visible and 0 or 1 })
	Animations.tween(text, "ease", { TextTransparency = visible and 0 or 1 })
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
