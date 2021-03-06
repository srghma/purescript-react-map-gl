module Map
  ( Messages(..)
  , MapMessages(..)
  , Commands(..)
  , mapClass
  ) where

import Prelude

import Affjax as Affjax
import Affjax.ResponseFormat as ResponseFormat
import Control.Lazy (fix)
import Data.Either (Either(..), either)
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), isJust)
import Data.Newtype (un)
import Data.Nullable (Nullable)
import Data.Nullable as Nullable
import Data.Tuple (snd)
import Debug.Trace
import Effect (Effect)
import Effect.Aff (error, launchAff_)
import Effect.Aff.Bus as Bus
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Effect.Class.Console as C
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Effect.Uncurried (mkEffectFn1)
import GeoJson as GeoJson
import MapGL (ClickInfo, InteractiveMap, Viewport(..))
import MapGL as MapGL
import Mapbox as Mapbox
import React as R
import React.Ref as R
import Record (disjointUnion)
import Simple.JSON as JSON
import Unsafe.Coerce (unsafeCoerce)


data MapMessages
  = OnClick ClickInfo

type MapRef = Ref (Maybe InteractiveMap)

data Commands
  = SetHeatmapVisibilty Boolean

data Messages
  = IsInitialized (Bus.BusW Commands)
  | PublicMsg MapMessages

type Props =
  { messages :: Bus.BusW Messages
  , width :: Number
  , height :: Number
  }

type State =
  { command :: Bus.BusRW Commands
  , viewport :: Viewport
  }

mapClass :: R.ReactClass Props
mapClass = R.component "Map" \this -> do
  mapRef <- liftEffect $ Ref.new Nothing
  command <- Bus.make
  { width, height, messages } <- R.getProps this
  launchAff_ $ Bus.write (IsInitialized $ snd $ Bus.split command) messages
  pure
    { componentDidMount: componentDidMount this mapRef
    , componentWillUnmount: componentWillUnmount this mapRef
    , render: render this mapRef
    , state:
        { viewport: Viewport
          { width
          , height
          , longitude: -100.0
          , latitude: 40.0
          , zoom: 3.0
          , pitch: 0.0
          , bearing: 0.0
          }
        , command
        }
    }
  where
    componentWillUnmount :: R.ReactThis Props State -> MapRef -> R.ComponentWillUnmount
    componentWillUnmount this mapRef = do
      liftEffect $ Ref.write Nothing mapRef
      { command } <- R.getState this
      launchAff_ $ do
        props <- liftEffect $ R.getProps this
        Bus.kill (error "kill from componentWillUnmount") command

    componentDidMount :: R.ReactThis Props State -> MapRef -> R.ComponentDidMount
    componentDidMount this mapRef = do
      { command } <- R.getState this
      launchAff_ $ fix \loop -> do
        msg <- Bus.read command
        case msg of
          SetHeatmapVisibilty visible -> liftEffect $ do
            iMap <- Ref.read mapRef
            for_ (MapGL.getMap =<< iMap) \map ->
              -- make sure a `heatmap-layer` is already available at this point
              when (isJust $ Mapbox.getSource map mapSourceId) $
                Mapbox.setLayerVisibilty map mapLayerId visible
        loop

    mapOnLoadHandler
      :: MapRef
      -> Effect Unit
    mapOnLoadHandler mapRef = do
      iMap <- Ref.read mapRef
      for_ (MapGL.getMap =<< iMap) \map -> do
        -- set initial (empty) data
        let (source :: HeatmapData) = Mapbox.mkGeoJsonSource $ GeoJson.mkFeatureCollection []
        Mapbox.addSource map mapSourceId source
        -- initial heatmap layer
        Mapbox.addLayer map heatmapLayer
        -- load data
        launchAff_ $ do
          result <- getMapData
          case result of
            Right mapData -> do
              -- update data of heatmap layer
              liftEffect $ Mapbox.setData map mapSourceId mapData
            Left err -> do
              liftEffect $ C.error $ "error while loading earthquake data: " <> show err
              pure unit


    instanceToInteractiveMap :: R.ReactInstance -> InteractiveMap
    instanceToInteractiveMap = unsafeCoerce

    mapRefHandler :: MapRef -> R.Ref R.ReactInstance -> Effect Unit
    mapRefHandler mapRef ref = do
      (content :: Maybe R.ReactInstance) <- R.getCurrentRef ref
      Ref.write (map instanceToInteractiveMap content) mapRef

    render :: R.ReactThis Props State -> MapRef -> R.Render
    render this mapRef = do
      { messages } <- R.getProps this
      { viewport } <- R.getState this
      pure $ R.createElement MapGL.mapGL
              (un MapGL.Viewport viewport `disjointUnion`
              { onViewportChange: mkEffectFn1 $ \vp ->
                  void $ R.setState this {viewport: vp}
              , onClick: mkEffectFn1 $ \info -> do
                  launchAff_ $ Bus.write (PublicMsg $ OnClick info) messages
              , onLoad: mapOnLoadHandler mapRef
              , mapStyle
              , mapboxApiAccessToken
              , ref: R.fromEffect $ mapRefHandler mapRef
              , dragRotate: true
              , touchZoom: true
              , touchRotate: true
              })
              []

mapStyle :: String
mapStyle = "mapbox://styles/mapbox/dark-v9"

mapboxApiAccessToken :: String
mapboxApiAccessToken = "pk.eyJ1IjoiYmxpbmt5MzcxMyIsImEiOiJjamVvcXZtbGYwMXgzMzNwN2JlNGhuMHduIn0.ue2IR6wHG8b9eUoSfPhTuQ"

data AjaxError
  = HTTPStatus String
  | ResponseError String
  | DecodingError String

instance showAjaxError :: Show AjaxError where
  show = case _ of
    HTTPStatus s -> "HTTP status error" <> s
    ResponseError s -> "Response error" <> s
    DecodingError s -> "Decode JSON error" <> s

getMapData
  :: forall m
  . MonadAff m
  => m (Either AjaxError HeatmapDataFeatureCollection)
getMapData = liftAff do
  resp <- Affjax.get ResponseFormat.string dataUrl
  case resp of
    Left err ->
      pure $ Left $ ResponseError $ Affjax.printError err
    Right {body: str} ->
      pure $ either (Left <<< DecodingError <<< show) pure (JSON.readJSON str)

dataUrl :: String
dataUrl = "https://docs.mapbox.com/mapbox-gl-js/assets/earthquakes.geojson"

type HeatmapData = Mapbox.GeoJsonSource HeatmapDataFeatureCollection
type HeatmapDataFeatureCollection = GeoJson.FeatureCollection HeatmapDataFeature
type HeatmapDataFeature = GeoJson.Feature GeoJson.PointGeometry HeatmapDataProps

type HeatmapDataProps =
  { id :: String
  , mag :: Number
  , time :: Number
  , felt :: Nullable Number
  , tsunami :: Number
  }

mapSourceId :: Mapbox.SourceId
mapSourceId = Mapbox.SourceId "heatmap-source"

mapLayerId :: Mapbox.LayerId
mapLayerId = Mapbox.LayerId "heatmap-layer"

maxZoom :: Number
maxZoom = 9.0

-- Increase the heatmap weight based on a property.
-- This property has to be defined in a `feature` of a `FeatureCollection`
heatmapWeight :: Mapbox.PaintProperty
heatmapWeight = Mapbox.mkPaintProperty "heatmap-weight"
  [ -- interpolate expression
    -- https://docs.mapbox.com/mapbox-gl-js/style-spec/#expressions-interpolate
    Mapbox.SEString "interpolate"
  , Mapbox.SEArray [Mapbox.SEString "linear"]
  -- "get" expression
  -- Retrieves a property value from the current feature's properties
  -- https://docs.mapbox.com/mapbox-gl-js/style-spec/#expressions-get
  , Mapbox.SEArray [Mapbox.SEString "get", Mapbox.SEString "mag"]
  , Mapbox.SENumber 0.0
  , Mapbox.SENumber 0.0
  , Mapbox.SENumber 6.0
  , Mapbox.SENumber 1.0
  ]

-- Increase the heatmap color weight weight by zoom level
-- heatmap-intensity is a multiplier on top of heatmap-weight
-- https://docs.mapbox.com/mapbox-gl-js/style-spec/#paint-heatmap-heatmap-intensity
heatmapIntensity :: Mapbox.PaintProperty
heatmapIntensity = Mapbox.mkPaintProperty "heatmap-intensity"
  [ Mapbox.SEString "interpolate"
  , Mapbox.SEArray [Mapbox.SEString "linear"]
  , Mapbox.SEArray [Mapbox.SEString "zoom"]
  , Mapbox.SENumber 0.0
  , Mapbox.SENumber 1.0
  , Mapbox.SENumber maxZoom
  , Mapbox.SENumber 3.0
  ]

-- Color ramp for heatmap.  Domain is 0 (low) to 1 (high).
-- Begin color ramp at 0-stop with a 0-transparancy color
-- to create a blur-like effect.
-- https://docs.mapbox.com/mapbox-gl-js/style-spec/#paint-heatmap-heatmap-color
heatmapColor :: Mapbox.PaintProperty
heatmapColor = Mapbox.mkPaintProperty "heatmap-color"
  [ Mapbox.SEString "interpolate"
  , Mapbox.SEArray [Mapbox.SEString "linear"]
  , Mapbox.SEArray [Mapbox.SEString "heatmap-density"]
  , Mapbox.SENumber 0.0
  , Mapbox.SEString "rgba(33,102,172,0)"
  , Mapbox.SENumber 0.2
  , Mapbox.SEString "rgb(103,169,207)"
  , Mapbox.SENumber 0.4
  , Mapbox.SEString "rgb(209,229,240)"
  , Mapbox.SENumber 0.6
  , Mapbox.SEString "rgb(253,219,199)"
  , Mapbox.SENumber 0.8
  , Mapbox.SEString "rgb(239,138,98)"
  , Mapbox.SENumber 0.9
  , Mapbox.SEString "rgb(255,201,101)"
  ]

-- Adjust the heatmap radius by zoom level
-- https://docs.mapbox.com/mapbox-gl-js/style-spec/#paint-heatmap-heatmap-radius
heatmapRadius :: Mapbox.PaintProperty
heatmapRadius = Mapbox.mkPaintProperty "heatmap-radius"
  [ Mapbox.SEString "interpolate"
  , Mapbox.SEArray [Mapbox.SEString "exponential", Mapbox.SENumber 1.75]
  , Mapbox.SEArray [Mapbox.SEString "zoom"]
  -- zoom is 0 -> radius will be 2px
  , Mapbox.SENumber 0.0
  , Mapbox.SENumber 2.0
  -- zoom is 9 -> radius will be 20px
  , Mapbox.SENumber maxZoom
  , Mapbox.SENumber 20.0
  ]

-- Transition from heatmap to circle layer by zoom level
-- https://docs.mapbox.com/mapbox-gl-js/style-spec/#paint-heatmap-heatmap-opacity
heatmapOpacity :: Mapbox.PaintProperty
heatmapOpacity = Mapbox.mkPaintProperty "heatmap-opacity"
  [ Mapbox.SEString "interpolate"
  , Mapbox.SEArray [Mapbox.SEString "linear"]
  , Mapbox.SEArray [Mapbox.SEString "zoom"]
  -- zoom is 7 (or less) -> opacity will be 1
  , Mapbox.SENumber 7.0
  , Mapbox.SENumber 1.0
  -- zoom is 9 (or greater) -> opacity will be 0
  , Mapbox.SENumber maxZoom
  , Mapbox.SENumber 0.0
  ]

paint :: Mapbox.Paint
paint = Mapbox.Paint
  [ heatmapWeight
  , heatmapIntensity
  , heatmapColor
  , heatmapRadius
  , heatmapOpacity
  ]

layout :: Mapbox.Layout
layout = Mapbox.HeatmapLayout { visibility: Mapbox.LayerNone }

heatmapLayer :: Mapbox.Layer
heatmapLayer = Mapbox.Layer
  { id: mapLayerId
  , source: mapSourceId
  , type: Mapbox.Heatmap
  , minzoom: 0.0
  , maxzoom: maxZoom
  , paint
  , layout
  }
