local gui

function OnWorldPreUpdate()
  if gui == nil then
    gui = GuiCreate()
  end
  GuiStartFrame(gui)
  GuiText(gui, 5, 5, 'test mod loaded')
end
