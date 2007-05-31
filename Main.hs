-----------------------------------------------------------------------------
-- |
-- Module      :  Main.hs
-- Copyright   :  (c) Spencer Janssen 2007
-- License     :  BSD3-style (see LICENSE)
--
-- Maintainer  :  sjanssen@cse.unl.edu
-- Stability   :  unstable
-- Portability :  not portable, uses mtl, X11, posix
--
-----------------------------------------------------------------------------
--
-- xmonad, a minimalist, tiling window manager for X11
--

import Data.Bits
import qualified Data.Map as M
import Control.Monad.Reader

import System.Environment (getArgs)

import Graphics.X11.Xlib hiding (refreshKeyboardMapping)
import Graphics.X11.Xlib.Extras
import Graphics.X11.Xinerama    (getScreenInfo)

import XMonad
import Config
import StackSet (new)
import Operations   (manage, unmanage, focus, setFocusX, full, isClient, rescreen, makeFloating, swapMaster)

--
-- The main entry point
--
main :: IO ()
main = do
    dpy   <- openDisplay ""
    let dflt = defaultScreen dpy
        initcolor c = fst `liftM` allocNamedColor dpy (defaultColormap dpy dflt) c

    rootw  <- rootWindow dpy dflt
    wmdelt <- internAtom dpy "WM_DELETE_WINDOW" False
    wmprot <- internAtom dpy "WM_PROTOCOLS"     False
    xinesc <- getScreenInfo dpy
    nbc    <- initcolor normalBorderColor
    fbc    <- initcolor focusedBorderColor
    args <- getArgs

    let winset | ("--resume" : s : _) <- args
               , [(x, "")]            <- reads s = x
               | otherwise = new (fromIntegral workspaces) (fromIntegral $ length xinesc)
        safeLayouts = case defaultLayouts of [] -> (full, []); (x:xs) -> (x, xs)
        cf = XConf
            { display       = dpy
            , theRoot       = rootw
            , wmdelete      = wmdelt
            , wmprotocols   = wmprot
            -- fromIntegral needed for X11 versions that use Int instead of CInt.
            , normalBorder  = nbc
            , focusedBorder = fbc
            }
        st = XState
            { windowset     = winset
            , layouts       = M.fromList [(w, safeLayouts) | w <- [0 .. W workspaces - 1]]
            , statusGaps    = take (length xinesc) $ defaultGaps ++ repeat (0,0,0,0)
            , xineScreens   = xinesc
            , dimensions    = (fromIntegral (displayWidth  dpy dflt),
                               fromIntegral (displayHeight dpy dflt)) }

    xSetErrorHandler -- in C, I'm too lazy to write the binding: dons

    -- setup initial X environment
    sync dpy False
    selectInput dpy rootw $  substructureRedirectMask .|. substructureNotifyMask
                         .|. enterWindowMask .|. leaveWindowMask .|. structureNotifyMask
    grabKeys dpy rootw
    sync dpy False

    ws <- scan dpy rootw
    allocaXEvent $ \e ->
        runX cf st $ do
            mapM_ manage ws
            -- main loop, for all you HOF/recursion fans out there.
            forever $ handle =<< io (nextEvent dpy e >> getEvent e)

      where forever a = a >> forever a

-- ---------------------------------------------------------------------
-- IO stuff. Doesn't require any X state
-- Most of these things run only on startup (bar grabkeys)

-- | scan for any initial windows to manage
scan :: Display -> Window -> IO [Window]
scan dpy rootw = do
    (_, _, ws) <- queryTree dpy rootw
    filterM ok ws

  where ok w = do wa <- getWindowAttributes dpy w
                  return $ not (wa_override_redirect wa)
                         && wa_map_state wa == waIsViewable

-- | Grab the keys back
grabKeys :: Display -> Window -> IO ()
grabKeys dpy rootw = do
    ungrabKey dpy anyKey anyModifier rootw
    flip mapM_ (M.keys keys) $ \(mask,sym) -> do
         kc <- keysymToKeycode dpy sym
         -- "If the specified KeySym is not defined for any KeyCode,
         -- XKeysymToKeycode() returns zero."
         when (kc /= '\0') $ mapM_ (grab kc . (mask .|.)) $
            [0, numlockMask, lockMask, numlockMask .|. lockMask]

  where grab kc m = grabKey dpy kc m rootw True grabModeAsync grabModeAsync

cleanMask :: KeyMask -> KeyMask
cleanMask = (complement (numlockMask .|. lockMask) .&.)

mouseDrag :: (XMotionEvent -> IO ()) -> X ()
mouseDrag f = do
    XConf { theRoot = root, display = d } <- ask
    io $ grabPointer d root False (buttonReleaseMask .|. pointerMotionMask) grabModeAsync grabModeAsync none none currentTime

    io $ allocaXEvent $ \p -> fix $ \again -> do
        maskEvent d (buttonReleaseMask .|. pointerMotionMask) p
        et <- get_EventType p
        when (et == motionNotify) $ get_MotionEvent p >>= f >> again

    io $ ungrabPointer d currentTime

mouseMoveWindow :: Window -> X ()
mouseMoveWindow w = withDisplay $ \d -> do
    io $ raiseWindow d w
    wa <- io $ getWindowAttributes d w
    (_, _, _, ox, oy, _, _, _) <- io $ queryPointer d w
    mouseDrag $ \(_, _, _, ex, ey, _, _, _, _, _) ->
        moveWindow d w (fromIntegral (fromIntegral (wa_x wa) + (ex - ox))) (fromIntegral (fromIntegral (wa_y wa) + (ey - oy)))

    makeFloating w

mouseResizeWindow :: Window -> X ()
mouseResizeWindow w = withDisplay $ \d -> do
    io $ raiseWindow d w
    wa <- io $ getWindowAttributes d w
    io $ warpPointer d none w 0 0 0 0 (fromIntegral (wa_width wa)) (fromIntegral (wa_height wa))
    mouseDrag $ \(_, _, _, ex, ey, _, _, _, _, _) ->
        resizeWindow d w (fromIntegral (max 1 (ex - fromIntegral (wa_x wa)))) (fromIntegral (max 1 (ey - fromIntegral (wa_y wa))))

    makeFloating w

-- ---------------------------------------------------------------------
-- | Event handler. Map X events onto calls into Operations.hs, which
-- modify our internal model of the window manager state.
--
-- Events dwm handles that we don't:
--
--    [ButtonPress]    = buttonpress,
--    [Expose]         = expose,
--    [PropertyNotify] = propertynotify,
--

handle :: Event -> X ()

-- run window manager command
handle (KeyEvent {ev_event_type = t, ev_state = m, ev_keycode = code})
    | t == keyPress = withDisplay $ \dpy -> do
        s  <- io $ keycodeToKeysym dpy code 0
        whenJust (M.lookup (cleanMask m,s) keys) id

-- manage a new window
handle (MapRequestEvent    {ev_window = w}) = withDisplay $ \dpy -> do
    wa <- io $ getWindowAttributes dpy w -- ignore override windows
    when (not (wa_override_redirect wa)) $ manage w

-- window destroyed, unmanage it
-- window gone,      unmanage it
handle (DestroyWindowEvent {ev_window = w}) = whenX (isClient w) $ unmanage w
handle (UnmapEvent         {ev_window = w}) = whenX (isClient w) $ unmanage w

-- set keyboard mapping
handle e@(MappingNotifyEvent {ev_window = w}) = do
    io $ refreshKeyboardMapping e
    when (ev_request e == mappingKeyboard) $ withDisplay $ io . flip grabKeys w

-- click on an unfocused window, makes it focused on this workspace
handle (ButtonEvent {ev_window = w, ev_event_type = t, ev_state = m, ev_button = b })
    | t == buttonPress && cleanMask m == modMask && b == button1 = mouseMoveWindow w
    | t == buttonPress && cleanMask m == modMask && b == button2 = focus w >> swapMaster
    | t == buttonPress && cleanMask m == modMask && b == button3 = mouseResizeWindow w
    | t == buttonPress = focus w

-- entered a normal window, makes this focused.
handle e@(CrossingEvent {ev_window = w, ev_event_type = t})
    | t == enterNotify && ev_mode   e == notifyNormal
                       && ev_detail e /= notifyInferior = focus w

-- left a window, check if we need to focus root
handle e@(CrossingEvent {ev_event_type = t})
    | t == leaveNotify
    = do rootw <- asks theRoot
         when (ev_window e == rootw && not (ev_same_screen e)) $ setFocusX rootw

-- configure a window
handle e@(ConfigureRequestEvent {}) = withDisplay $ \dpy -> do
    io $ configureWindow dpy (ev_window e) (ev_value_mask e) $ WindowChanges
        { wc_x            = ev_x e
        , wc_y            = ev_y e
        , wc_width        = ev_width e
        , wc_height       = ev_height e
        , wc_border_width = ev_border_width e
        , wc_sibling      = ev_above e
        -- this fromIntegral is only necessary with the old X11 version that uses
        -- Int instead of CInt.  TODO delete it when there is a new release of X11
        , wc_stack_mode   = fromIntegral $ ev_detail e }
    io $ sync dpy False

-- the root may have configured
handle (ConfigureEvent {ev_window = w}) = whenX (isRoot w) rescreen

handle _ = return () -- trace (eventName e) -- ignoring
