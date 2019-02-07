module MapComponent
  ( MapQuery(..)
  , Messages(..)
  , MapProps
  , MapMessages(..)
  , Commands(..)
  , mapComponent
  ) where

import Prelude

import Affjax as Affjax
import Affjax.ResponseFormat as ResponseFormat
import Affjax.StatusCode (StatusCode(..))
import Control.Lazy (fix)
import Data.Either (Either(..), either)
import Data.Foldable (for_)
import Data.Int (toNumber)
import Data.Maybe (Maybe(..))
import Data.Newtype (un)
import Data.Nullable (Nullable)
import Data.Nullable as Nullable
import Data.Tuple (snd)
import Effect (Effect)
import Effect.Aff (error, launchAff_)
import Effect.Aff.Bus as Bus
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class.Console as C
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Effect.Uncurried (mkEffectFn1)
import GeoJson as GeoJson
import Halogen (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.Query.EventSource as ES
import MapGL (ClickInfo, InteractiveMap, Viewport(..))
import MapGL as MapGL
import Mapbox as Mapbox
import Partial.Unsafe (unsafeCrashWith)
import React as R
import ReactDOM (render) as RDOM
import Record (disjointUnion)
import Simple.JSON as JSON
import Unsafe.Coerce (unsafeCoerce)
import Web.HTML (window)
import Web.HTML.HTMLElement as HTMLElement
import Web.HTML.Window as Window


type MapState = Maybe (Bus.BusW Commands)

type MapProps = Unit

data MapQuery a
  = Initialize a
  | HandleMessages Messages a
  | ToggleHeatmap a

data MapMessages
  = OnClick ClickInfo

mapComponent :: forall m. MonadAff m => H.Component HH.HTML MapQuery MapProps MapMessages m
mapComponent =
  H.lifecycleComponent
    { initialState: const initialState
    , render
    , eval
    , initializer: Just (H.action Initialize)
    , finalizer: Nothing
    , receiver: const Nothing
    }
  where

  initialState :: MapState
  initialState = Nothing

  render :: MapState -> H.ComponentHTML MapQuery
  render = const $
    HH.div 
      [ HP.class_ $ HH.ClassName "map-wrapper" ] 
      [ HH.div [ HP.ref (H.RefLabel "map") ] []
      , HH.button
          [ HP.class_ $ HH.ClassName "btn-toggle"
          , HE.onClick $ HE.input_ ToggleHeatmap
          ]
          [ HH.text "Toggle heatmap" ]
      ]

  eval :: MapQuery ~> H.ComponentDSL MapState MapQuery MapMessages m
  eval = case _ of
    Initialize next -> do
      H.getHTMLElementRef (H.RefLabel "map") >>= case _ of
        Nothing -> unsafeCrashWith "There must be an element with ref `map`"
        Just el' -> do
          win <- liftEffect window
          width <- liftEffect $ toNumber <$> Window.innerWidth win
          height <- liftEffect $ toNumber <$> Window.innerHeight win
          messages <- liftAff Bus.make
          liftEffect $ void $ RDOM.render (R.createLeafElement mapClass { messages: snd $ Bus.split messages, width, height}) (HTMLElement.toElement el')
          H.subscribe $ H.eventSource (\emit -> launchAff_ $ fix \loop -> do
              Bus.read messages >>= emit >>> liftEffect
              loop
            )
            (Just <<< flip HandleMessages ES.Listening)
      pure next
    HandleMessages msg next -> do
      case msg of
        PublicMsg msg' -> H.raise msg'
        IsInitialized bus -> H.put $ Just bus
      pure next
    ToggleHeatmap next -> do 
      mbBus <- H.get
      for_ mbBus \bus ->
        liftAff $ Bus.write ToggleHeatmap' bus
      pure next

type MapRef = Ref (Maybe InteractiveMap)

data Commands
  = ToggleHeatmap'

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
  , showHeatmap :: Boolean
  }

mapClass :: R.ReactClass Props
mapClass = R.component "Map" \this -> do
  mapRef <- H.liftEffect $ Ref.new Nothing
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
        , showHeatmap: true
        }
    }
  where
    componentWillUnmount :: R.ReactThis Props State -> MapRef -> R.ComponentWillUnmount
    componentWillUnmount this mapRef = do
      H.liftEffect $ Ref.write Nothing mapRef
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
          ToggleHeatmap' -> liftEffect $ do
            {showHeatmap} <- R.getState this
            let visible = not showHeatmap
            iMap <- Ref.read mapRef
            for_ (MapGL.getMap =<< iMap) \map -> do
              Mapbox.setLayerVisibilty map mapLayerId visible
            R.setState this {showHeatmap: visible}
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
  
    mapRefHandler :: MapRef -> (Nullable R.ReactRef)-> Effect Unit
    mapRefHandler mapRef ref =
      Ref.write (Nullable.toMaybe $ unsafeCoerce ref) mapRef

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
              , ref: mkEffectFn1 $ mapRefHandler mapRef
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
  {body, status} <- Affjax.get ResponseFormat.string dataUrl
  if (status /= StatusCode 200) 
    then
      pure $ Left $ HTTPStatus $ show status
    else
      case body of 
        Left err ->
          pure $ Left $ ResponseError $ Affjax.printResponseFormatError err
        Right str -> 
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
  , Mapbox.SEArray ["linear"]
  -- "get" expression
  -- Retrieves a property value from the current feature's properties
  -- https://docs.mapbox.com/mapbox-gl-js/style-spec/#expressions-get
  , Mapbox.SEArray ["get", "mag"]
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
  , Mapbox.SEArray ["linear"]
  , Mapbox.SEArray ["zoom"]
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
  , Mapbox.SEArray ["linear"]
  , Mapbox.SEArray ["heatmap-density"]
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
  , Mapbox.SEArray ["linear"]
  , Mapbox.SEArray ["zoom"]
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
  , Mapbox.SEArray ["linear"]
  , Mapbox.SEArray ["zoom"]
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

heatmapLayer :: Mapbox.Layer
heatmapLayer = Mapbox.Layer
  { id: mapLayerId
  , source: mapSourceId
  , type: Mapbox.Heatmap
  , minzoom: 0.0
  , maxzoom: maxZoom 
  , paint
  }