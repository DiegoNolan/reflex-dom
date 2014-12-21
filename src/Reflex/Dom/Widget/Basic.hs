{-# LANGUAGE ScopedTypeVariables, LambdaCase, ConstraintKinds, TypeFamilies, FlexibleContexts #-}
module Reflex.Dom.Widget.Basic where

import Reflex.Dom.Class

import Reflex
import Reflex.Host.Class
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Dependent.Sum (DSum (..))
import Control.Monad.Trans
import Control.Monad.Reader
import Control.Monad.Ref
import GHCJS.DOM.Node
import GHCJS.DOM.UIEvent
import GHCJS.DOM.EventM (event, Signal)
import GHCJS.DOM.Document
import GHCJS.DOM.Element
import GHCJS.DOM.HTMLElement
import GHCJS.DOM.Types hiding (Widget (..), unWidget, Event)
import GHCJS.DOM.NamedNodeMap
import Control.Lens
import Data.Monoid
import Data.These
import Data.Align

type Attributes = Map String String

data El t
  = El { _el_element :: Dynamic t (Maybe HTMLElement)
       , _el_clicked :: Event t ()
       , _el_keypress :: Event t Int
       }

buildElement :: MonadWidget t m => String -> Either Attributes (Dynamic t Attributes) -> m a -> m (HTMLElement, a)
buildElement elementTag attrs child = do
  doc <- askDocument
  p <- askParent
  Just e <- liftIO $ documentCreateElement doc elementTag
  either addStaticAttributes addDynamicAttributes attrs e
  _ <- liftIO $ nodeAppendChild p $ Just e
--  result <- local (widgetEnvParent .~ toNode e) $ unWidget child
  result <- subWidget (toNode e) child
  return (castToHTMLElement e, result) --TODO: events --TODO: Element doesn't need to be Dynamic or Maybe

addStaticAttributes :: (MonadIO m, IsElement e) => Attributes -> e -> m ()
addStaticAttributes curAttrs e = liftIO $ imapM_ (elementSetAttribute e) curAttrs

addDynamicAttributes :: (MonadWidget t m, IsElement e) => Dynamic t Attributes -> e -> m ()
addDynamicAttributes attrs e = do
  schedulePostBuild $ do
    curAttrs <- sample $ current attrs
    liftIO $ imapM_ (elementSetAttribute e) curAttrs
  addVoidAction $ flip fmap (updated attrs) $ \newAttrs -> liftIO $ do
    oldAttrs <- maybe (return Set.empty) namedNodeMapGetNames =<< elementGetAttributes e
    forM_ (Set.toList $ oldAttrs `Set.difference` Map.keysSet newAttrs) $ elementRemoveAttribute e
    imapM_ (elementSetAttribute e) newAttrs --TODO: avoid re-setting unchanged attributes; possibly do the compare using Align in haskell

namedNodeMapGetNames :: IsNamedNodeMap self => self -> IO (Set String)
namedNodeMapGetNames self = do
  l <- namedNodeMapGetLength self
  let locations = if l == 0 then [] else [0..l-1] -- Can't use 0..l-1 if l is 0 because l is unsigned and will wrap around
  liftM Set.fromList $ forM locations $ \i -> do
    Just n <- namedNodeMapItem self i
    nodeGetNodeName n

text :: MonadWidget t m => String -> m ()
text = void . text'

--TODO: Wrap the result
text' :: MonadWidget t m => String -> m Text
text' s = do
  doc <- askDocument
  p <- askParent
  Just n <- liftIO $ documentCreateTextNode doc s
  _ <- liftIO $ nodeAppendChild p $ Just n
  return n

dynText :: MonadWidget t m => Dynamic t String -> m ()
dynText s = do
  n <- text' ""
  schedulePostBuild $ do
    curS <- sample $ current s
    liftIO $ nodeSetNodeValue n curS
  addVoidAction $ fmap (liftIO . nodeSetNodeValue n) $ updated s

dyn :: -- (Reflex t, MonadHold t m, MonadSample t m, HasDocument m, MonadIO m, HasPostGui t h m, ReflexHost t, MonadReflexCreateTrigger t m, MonadRef m, Ref m ~ Ref IO) =>
       MonadWidget t m => Dynamic t (m a) -> m ()
dyn child = do
  startPlaceholder <- text' ""
  endPlaceholder <- text' ""
  (newChildVoidAction, newChildVoidActionTriggerRef) <- newEventWithTriggerRef
  childVoidAction <- hold never newChildVoidAction
  addVoidAction $ switch childVoidAction
  doc <- askDocument
  let build c = do
        Just df <- liftIO $ documentCreateDocumentFragment doc
        result <- runWidget df c
        runFrameWithTriggerRef newChildVoidActionTriggerRef $ snd result
        Just p <- liftIO $ nodeGetParentNode endPlaceholder
        liftIO $ nodeInsertBefore p (Just df) (Just endPlaceholder)
        return ()
  schedulePostBuild $ do
    c <- sample $ current child
    build c
  addVoidAction $ flip fmap (updated child) $ \newChild -> do
    liftIO $ deleteBetweenExclusive startPlaceholder endPlaceholder
    build newChild
  return ()

--TODO: Something better than Dynamic t (Map k v) - we want something where the Events carry diffs, not the whole value
listWithKey :: (Ord k, MonadWidget t m) => Dynamic t (Map k v) -> (k -> Dynamic t v -> m a) -> m (Dynamic t (Map k a))
  --forall t h m k v a. (Show k, Ord k, Reflex t, MonadHold t m, MonadSample t m, HasDocument m, MonadIO m, HasPostGui t h m, ReflexHost t, MonadReflexCreateTrigger t m, MonadRef m, Ref m ~ Ref IO) => Dynamic t (Map k v) -> (k -> Dynamic t v -> Widget t m a) -> Widget t m (Dynamic t (Map k a))
listWithKey vals mkChild = do
  doc <- askDocument
  startPlaceholder <- text' ""
  endPlaceholder <- text' ""
  (newChildren, newChildrenTriggerRef) <- newEventWithTriggerRef
  children <- hold Map.empty newChildren
  addVoidAction $ switch $ fmap (mergeWith (>>) . map snd . Map.elems) children
  let buildChild df k v = runWidget df $ do
        childStart <- text' ""
        result <- mkChild k =<< holdDyn v (fmapMaybe (Map.lookup k) (updated vals))
        childEnd <- text' ""
        return (result, (childStart, childEnd))
  schedulePostBuild $ do
    Just df <- liftIO $ documentCreateDocumentFragment doc
    curVals <- sample $ current vals
    initialState <- iforM curVals $ buildChild df
    runFrameWithTriggerRef newChildrenTriggerRef initialState --TODO: Do all these in a single runFrame
    Just p <- liftIO $ nodeGetParentNode endPlaceholder
    liftIO $ nodeInsertBefore p (Just df) (Just endPlaceholder)
    return ()
  addVoidAction $ flip fmap (updated vals) $ \newVals -> do
    curState <- sample children
    --TODO: Should we remove the parent from the DOM first to avoid reflows?
    newState <- liftM (Map.mapMaybe id) $ iforM (align curState newVals) $ \k -> \case
      This ((_, (start, end)), _) -> do
        liftIO $ deleteBetweenInclusive start end
        return Nothing
      That v -> do
        Just df <- liftIO $ documentCreateDocumentFragment doc
        s <- buildChild df k v
        let placeholder = case Map.lookupGT k curState of
              Nothing -> endPlaceholder
              Just (_, ((_, (start, _)), _)) -> start
        Just p <- liftIO $ nodeGetParentNode placeholder
        liftIO $ nodeInsertBefore p (Just df) (Just placeholder)
        return $ Just s
      These state _ -> do
        return $ Just state
    runFrameWithTriggerRef newChildrenTriggerRef newState
  holdDyn Map.empty $ fmap (fmap (fst . fst)) newChildren

--------------------------------------------------------------------------------
-- Basic DOM manipulation helpers
--------------------------------------------------------------------------------

-- | s and e must both be children of the same node and s must precede e
deleteBetweenExclusive s e = do
  Just currentParent <- nodeGetParentNode e -- May be different than it was at initial construction, e.g., because the parent may have dumped us in from a DocumentFragment
  let go = do
        Just x <- nodeGetPreviousSibling e -- This can't be Nothing because we should hit 's' first
        done <- nodeIsEqualNode s $ Just x
        when (not done) $ do
          nodeRemoveChild currentParent $ Just x
          go
  go

-- | s and e must both be children of the same node and s must precede e
deleteBetweenInclusive s e = do
  Just currentParent <- nodeGetParentNode e -- May be different than it was at initial construction, e.g., because the parent may have dumped us in from a DocumentFragment
  let go = do
        Just x <- nodeGetPreviousSibling e -- This can't be Nothing because we should hit 's' first
        nodeRemoveChild currentParent $ Just x
        done <- nodeIsEqualNode s $ Just x
        when (not done) go
  go
  nodeRemoveChild currentParent $ Just e

--------------------------------------------------------------------------------
-- Adapters
--------------------------------------------------------------------------------

--TODO: Get rid of extra version of this function
wrapDomEvent element elementOnevent getValue = do
  postGui <- askPostGui
  runWithActions <- askRunWithActions
  e <- newEventWithTrigger $ \et -> do
        unsubscribe <- {-# SCC "a" #-} liftIO $ {-# SCC "b" #-} elementOnevent element $ {-# SCC "c" #-} do
          v <- {-# SCC "d" #-} getValue
          liftIO $ postGui $ runWithActions [et :=> v]
        return $ liftIO $ do
          {-# SCC "e" #-} unsubscribe
  return $! {-# SCC "f" #-} e

wrapElement :: (Functor (Event t), MonadIO m, MonadSample t m, MonadReflexCreateTrigger t m, Reflex t, HasPostGui t h m) => HTMLElement -> m (El t)
wrapElement e = do
  clicked <- wrapDomEvent e elementOnclick (return ())
  keypress <- wrapDomEvent e elementOnkeypress $ liftIO . uiEventGetKeyCode =<< event
  return $ El (constDyn $ Just e) clicked keypress  

elDynAttr' elementTag attrs child = do
  (e, result) <- buildElement elementTag (Right attrs) child
  e' <- wrapElement e
  return (e', result)

{-# INLINABLE elAttr #-}
elAttr :: forall t m a. MonadWidget t m => String -> Map String String -> m a -> m a
elAttr elementTag attrs child = do
  (_, result) <- buildElement elementTag (Left attrs) child
  return result

{-# INLINABLE el' #-}
--el' :: forall t m a. MonadWidget t m => String -> m a -> m (El t, a)
el' tag child = elAttr' tag Map.empty child

{-# INLINABLE elAttr' #-}
--elAttr' :: forall t m a. MonadWidget t m => String -> Map String String -> m a -> m (El t, a)
elAttr' elementTag attrs child = do
  (e, result) <- buildElement elementTag (Left attrs) child
  e' <- wrapElement e
  return (e', result)

{-# INLINABLE elDynAttr #-}
elDynAttr :: forall t m a. MonadWidget t m => String -> Dynamic t (Map String String) -> m a -> m a
elDynAttr elementTag attrs child = do
  (_, result) <- buildElement elementTag (Right attrs) child
  return result

{-# INLINABLE el #-}
el :: forall t m a. MonadWidget t m => String -> m a -> m a
el tag child = elAttr tag Map.empty child

--------------------------------------------------------------------------------
-- Copied and pasted from Reflex.Widget.Class
--------------------------------------------------------------------------------

list dm mkChild = listWithKey dm (\_ dv -> mkChild dv)

{-

--TODO: Update dynamically
{-# INLINABLE dynHtml #-}
dynHtml :: MonadWidget t m => Dynamic t String -> m ()
dynHtml ds = do
  let mkSelf h = do
        doc <- askDocument
        Just e <- liftIO $ liftM (fmap castToHTMLElement) $ documentCreateElement doc "div"
        liftIO $ htmlElementSetInnerHTML e h
        return e
  eCreated <- performEvent . fmap mkSelf . tagDyn ds =<< getEInit
  putEChildren $ fmap ((:[]) . toNode) eCreated

-}