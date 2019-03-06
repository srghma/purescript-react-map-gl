module MapGL
  ( Viewport(..)
  , InteractiveMap
  , OnViewportChange
  , ClickInfo
  , OnLoadMap
  , OnClickMap
  , MapProps
  , MapPropsR
  , mkProps
  , mapGL
  , defaultProps
  , getMap
  ) where

import Prelude

import Data.Function.Uncurried (Fn1, runFn1)
import Data.Generic.Rep (class Generic)
import Data.Generic.Rep.Show (genericShow)
import Data.Maybe (Maybe)
import Data.Newtype (class Newtype)
import Data.Nullable (Nullable)
import Data.Nullable as Nullable
import Effect (Effect)
import Effect.Uncurried (EffectFn1)
import Mapbox (Map)
import React as R
import Record (disjointUnion)
import WebMercator.LngLat (LngLat)
import WebMercator.Viewport (ViewportR)


-- TODO(safareli) add animation props to Viewport

-- | `Viewport` is the most basic state type for the map component.
newtype Viewport =
  Viewport (Record (ViewportR ()))

derive instance genericViewport :: Generic Viewport _
derive instance newtypeViewport :: Newtype Viewport _
derive instance eqViewport :: Eq Viewport

instance showViewport :: Show Viewport where
  show = genericShow

-- | A handler to be run whenever the viewport changes
type OnViewportChange = EffectFn1 Viewport Unit

-- | The type exposed by the picking engine (abbreviated).
-- | - `latLng`: The latitude and longitude of the point picked.
type ClickInfo =
  { lngLat :: LngLat
  }

-- | The onLoad callback for the map
type OnLoadMap = Effect Unit

-- | A handler to run when the picking engine fires.
type OnClickMap = EffectFn1 ClickInfo Unit

type MapPropsR r =
  ( onLoad :: OnLoadMap
  , onViewportChange :: OnViewportChange
  , onClick :: OnClickMap
  , mapStyle :: String
  , mapboxApiAccessToken :: String
  , children :: R.Children
  , dragRotate :: Boolean
  , touchZoomRotate :: Boolean
  | r
  )

type MapProps = Record (ViewportR (MapPropsR ()))

mkProps :: Viewport -> Record (MapPropsR ()) -> MapProps
mkProps (Viewport vp) rest = disjointUnion rest vp

foreign import mapGL :: R.ReactClass MapProps
foreign import defaultProps :: MapProps

-- Default map component by `ReactMapGL` to render `MapboxGL`
-- https://github.com/uber/react-map-gl/blob/master/docs/components/interactive-map.md
foreign import data InteractiveMap :: Type

foreign import getMapImpl :: Fn1 InteractiveMap (Nullable Map)
getMap :: InteractiveMap -> Maybe Map
getMap = Nullable.toMaybe <<< runFn1 getMapImpl
