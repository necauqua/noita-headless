local gui

function OnWorldPreUpdate()
  if gui == nil then
    gui = GuiCreate()
  end
  GuiStartFrame(gui)
  GuiText(gui, 10, 10, 'test mod loaded')
end
