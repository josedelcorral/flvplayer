/*
  flvplayer v1.6
*/
import com.bomberstudios.utils.Delegate;
import com.bomberstudios.fx.DropShadow;
import com.bomberstudios.text.Styles;
import flash.geom.Rectangle; // needed for fullscreen hardware scaling

class com.bomberstudios.video.Player {
  var audio:Sound;
  var mc:MovieClip;
  var video_mc:MovieClip;
  var ns:NetStream;
  var nc:NetConnection;

  // Video status
  var is_playing:Boolean = false;
  var is_paused:Boolean = false;
  var is_streaming:Boolean = false;
  var audio_muted:Boolean;
  var has_streaming:Boolean = false;
  var started:Boolean;
  var run_loop_id:Number;
  var fullscreen_available:Boolean = false;
  var buffer_flushed:Boolean = false;
  var buffer_empty:Boolean = false;

  var BUFFER_TIME:Number = 3;

  // Idle detection
  private var ui_idle_count:Number = 0;
  private var ui_idle_xmouse:Number = 0;
  private var ui_idle_ymouse:Number = 0;
  private var UI_IDLE_LIMIT:Number = 100;

  // Video Metadata
  var metadata:Object;
  var cue_markers:Array;

  // HTML Variables
  var aspect_ratio:Number = 4/3;
  var $video_path:String;
  var $placeholder_path:String;
  var $stealth_mode:Boolean = false;

  // Some constants for UI redrawing
  var BUTTON_MARGIN:Number = 3;
  var RUN_LOOP_SLEEP:Number = 25;

  // Levels for movieclips
  var LEVEL_VIDEODISPLAY:Number         = 100;
  var LEVEL_PLACEHOLDER:Number          = 150;
  var LEVEL_WATERMARK:Number            = 170;
  var LEVEL_TRANSPORT:Number            = 200;
  var LEVEL_TRANSPORT_BG_LEFT:Number      = 100;
  var LEVEL_TRANSPORT_BG_CENTER:Number    = 200;
  var LEVEL_TRANSPORT_BG_RIGHT:Number     = 300;
  var LEVEL_SOUND:Number                = 300;
  var LEVEL_BTN_PLAY:Number             = 400;
  var LEVEL_ICO_SOUND:Number            = 500;
  var LEVEL_ICO_FULLSCREEN:Number       = 600;
  var LEVEL_PROGRESS_BG:Number          = 700;
  var LEVEL_PROGRESS_LOAD:Number        = 800;
  var LEVEL_PROGRESS_POSITION:Number    = 900;
  var LEVEL_CUE_MARKERS:Number          = 9000;
  var LEVEL_MESSAGE:Number              = 10000;


  function Player(_mc:MovieClip, init_options:Object){
    Stage.scaleMode = "noScale";
    Stage.align = "TL";
    mc = _mc.createEmptyMovieClip('v',_mc.getNextHighestDepth());
    // Parse options
    for(var option:String in init_options){
      switch option {
        case undefined:
          break;
        default:
          this[option] = init_options[option];
        case 'watermark':
          load_watermark(init_options.watermark);
        case 'placeholder_path':
          load_placeholder(init_options.placeholder_path);
      }
    }
    cue_markers = [];
    create_ui();
    setup_video();
    start_run_loop();
  }
  function toString():String{
    return "FLVPlayer v1.0";
  }
  private function setup_video(){
    nc = new NetConnection();
    nc.connect(null);
    ns = new NetStream(nc);
    ns.setBufferTime(BUFFER_TIME);

    // create and set sound object
    var snd:MovieClip = mc.createEmptyMovieClip("snd", LEVEL_SOUND);
    snd.attachAudio(ns);
    audio = new Sound(snd);

    // attach video
    video_mc.attachVideo(ns);

    // Video events...
    ns.onStatus = Delegate.create(this,on_video_status);
    ns.onMetaData = Delegate.create(this,on_video_metadata);

    // Set play status
    started = false;
    is_playing = false;
  }


  // Video Data
  public function get video_path():String {
    return $video_path;
  }
  public function set video_path(s:String) {
    $video_path = s;
  }
  public function set placeholder_path(s:String){
    $placeholder_path = s;
  }
  public function set stealth_mode(s:Boolean){
    $stealth_mode = s;
    ui_idle_count = UI_IDLE_LIMIT + 1;
  }
  public function get stealth_mode():Boolean{
    return $stealth_mode;
  }

  // Transport
  function play(){
    is_paused = false;
    if(!is_playing){
      is_playing = true;
      ns.play(video_path);
    } else {
      ns.pause(false);
    }
    show_pause_button();
  }
  function pause(){
    if(is_paused){
      show_pause_button();
    } else {
      show_play_button();
    }
    is_paused = !is_paused;
    ns.pause();
  }
  function toggle_play(){
    hide_placeholder();
    if(is_playing){
      pause();
    } else {
      play();
    }
  }
  function seek_to(time_in_seconds:Number){
    // Possible scenarios:
    // - no streaming
    // - streaming, seek to future
    // - streaming, seek to past (not available data)
    if (has_streaming) {
      if(time_in_seconds < ns.time || time_to_bytes(time_in_seconds) > ns.bytesLoaded){
        // show buffering banner
        display_message('Buffering');

        // special case for 0
        if (time_in_seconds == 0) {
          stream_to(0);
          return;
        }

        var times:Array = metadata.keyframes.times;
        var positions:Array = metadata.keyframes.filepositions;
        var tofind:Number = time_in_seconds;
        for (var i:Number = 0; i < times.length; i++) {
          var j:Number = i + 1;
          if ((times[i] <= tofind) && (times[j] >= tofind)) {
            stream_to(positions[i]);
            return;
          }
        }
      } else {
        ns.seek(time_in_seconds);
      }
    } else {
      ns.seek(time_in_seconds);
    }
  }
  function stream_to(position_in_bytes:Number){
    video_path = video_path.split('?start')[0] + "?start=" + position_in_bytes;
    ns.play(video_path);
    if (is_paused) {
      // workaround for #1
      is_paused = false;
      show_pause_button();
    }
  }


  // Run loop
  private function start_run_loop(){
    run_loop_id = setInterval(Delegate.create(this,on_run_loop),RUN_LOOP_SLEEP);
    redraw();
  }
  private function on_run_loop(){

    update_progress_bar();

    // Hide / show transport bar
    if (ui_idle_xmouse != mc._xmouse && ui_idle_xmouse != 0 || ui_idle_ymouse != mc._ymouse && ui_idle_ymouse != 0) {
      ui_idle_count = 0;
    } else {
      ui_idle_count += 1;
    }
    if (ui_idle_count < UI_IDLE_LIMIT) {
      show_transport();
    } else {
      hide_transport();
    }
    ui_idle_xmouse = mc._xmouse;
    ui_idle_ymouse = mc._ymouse;
    if (is_playing) {
      hide_placeholder();
    }
  }


  // Events
  function on_rollover_btn(btn:MovieClip){
    btn.attachMovie(btn._name + "_over",btn._name,1);
  }
  function on_rollout_btn(btn:MovieClip){
    btn.attachMovie(btn._name,btn._name,1);
  }
  function on_video_status(s:Object){
    for (var st:String in s){
      trace(st + ": " + s[st]);
    }
    switch (s.code) {
      case "NetStream.Buffer.Full":
        hide_message();
        break;
      case "NetStream.Play.Stop":
        //on_video_end();
        break;
      case "NetStream.Buffer.Flush":
        buffer_flushed = true;
        break;
      case "NetStream.Buffer.Empty":
        if (buffer_flushed) {
          buffer_empty = true;
          on_video_end();
        }
        break;
    }
  }
  function on_video_metadata(s:Object){
    for (var st:String in s){
      trace(st + ": " + s[st]);
    }
    // set aspect ratio
    aspect_ratio = s.width / s.height;
    metadata = s;
    for(var key:String in metadata){
      if (key == "cuePoints") {
        on_cue_markers(s[key]);
      }
    }
    redraw();
  }
  function on_cue_markers(markers_array:Array){
    for(var key:String in markers_array){
      cue_markers.push({id: key, name: markers_array[key].name, time: markers_array[key].time});
    }
  }
  function on_cue_marker_rollover(txt:String){
    display_message(txt);
  }
  function on_cue_marker_rollout(){
    hide_message();
  }
  function onResize(e:Object){
    redraw();
  }
  function on_video_end(){
    ns.close();
    is_playing = false;
    buffer_empty = false;
    buffer_flushed = false;
    show_placeholder();
    show_play_button();
  }
  function on_progress_bar_click(){
    hide_placeholder();
    var x_pos:Number = mc._xmouse - (mc.transport._x + mc.transport.progress_bar_bg._x);
    seek_to(position_to_time(x_pos));
  }


  // UI
  public function set fullscreen_enabled(v:Boolean){
    fullscreen_available = v;
    redraw();
  }
  function set_width(w:Number){
    video_mc._width = Math.floor(w);
    video_mc._height = Math.floor(w / aspect_ratio);
    redraw_transport();
  }
  function hide_transport(){
    mc.transport._visible = false;
  }
  function show_transport(){
    mc.transport._visible = true;
  }
  private function create_ui(){
    // Video display
    mc.attachMovie('VideoDisplay','VideoDisplay',LEVEL_VIDEODISPLAY);
    video_mc = mc.VideoDisplay.vid;

    // Transport bar
    mc.createEmptyMovieClip('transport',LEVEL_TRANSPORT);
    mc.transport.attachMovie('bg_left','bg_left',LEVEL_TRANSPORT_BG_LEFT);
    mc.transport.attachMovie('bg_center','bg_center',LEVEL_TRANSPORT_BG_CENTER,{_x:mc.transport.bg_left._width});
    mc.transport.attachMovie('bg_right','bg_right',LEVEL_TRANSPORT_BG_RIGHT,{_x:mc.transport.bg_center._x + mc.transport.bg_center._width});

    // Play button
    show_play_button();

    // Fullscreen button
    mc.transport.attachMovie('ico_fullscreen','ico_fullscreen',LEVEL_ICO_FULLSCREEN,{_x:mc.transport._width - 22, _y:BUTTON_MARGIN});
    make_button(mc.transport.ico_fullscreen,Delegate.create(this,toggle_fullscreen));

    // Sound button
    mc.transport.attachMovie('ico_sound','ico_sound',LEVEL_ICO_SOUND,{_x:mc.transport._width - 44, _y:BUTTON_MARGIN});
    make_button(mc.transport.ico_sound,Delegate.create(this,toggle_audio));

    // Progress bar
    var progress_bar_position:Number = mc.transport.btn_play._x + mc.transport.btn_play._width + ( BUTTON_MARGIN * 2 );
    mc.transport.attachMovie('progress_bar_bg','progress_bar_bg',LEVEL_PROGRESS_BG,{_x:progress_bar_position});
    mc.transport.attachMovie('progress_bar_load','progress_bar_load',LEVEL_PROGRESS_LOAD,{_x:progress_bar_position,_width: 0});
    mc.transport.attachMovie('progress_bar_position','progress_bar_position',LEVEL_PROGRESS_POSITION,{_x:progress_bar_position,_width:0});
    mc.transport.progress_bar_bg.onRelease = Delegate.create(this,on_progress_bar_click);

    // Hide transport
    hide_transport();
  }
  private function redraw(){
    var tentative_video_height:Number = Stage.width / aspect_ratio;
    if(tentative_video_height > Stage.height){
      set_width(Stage.height * aspect_ratio);
    } else {
      set_width(Stage.width);
    }
    // Fullscreen button
    mc.transport.ico_fullscreen._visible = fullscreen_available;

    position_watermark();
    center_on_stage(mc.placeholder);
    center_on_stage(video_mc);
  }
  private function redraw_transport(){
    mc.transport.bg_center._width = Stage.width - mc.transport.bg_left._width - mc.transport.bg_right._width;
    mc.transport.bg_right._x = Stage.width - mc.transport.bg_right._width;
    if (fullscreen_available) {
      mc.transport.ico_sound._x = Stage.width - mc.transport.ico_sound._width - mc.transport.ico_fullscreen._width - (BUTTON_MARGIN*2);
      mc.transport.ico_sound_muted._x = Stage.width - mc.transport.ico_sound_muted._width - mc.transport.ico_fullscreen._width - (BUTTON_MARGIN*2);
      mc.transport.ico_fullscreen._x = Stage.width - mc.transport.ico_fullscreen._width - BUTTON_MARGIN;
      mc.transport.ico_sound._y = mc.transport.ico_sound_muted._y = mc.transport.ico_fullscreen._y = BUTTON_MARGIN;
    } else {
      mc.transport.ico_sound._x = Stage.width - mc.transport.ico_sound._width - BUTTON_MARGIN;
      mc.transport.ico_sound_muted._x = Stage.width - mc.transport.ico_sound_muted._width - BUTTON_MARGIN;
      mc.transport.ico_sound._y = mc.transport.ico_sound_muted._y = BUTTON_MARGIN;
    }
    if (mc.transport.ico_sound) {
      mc.transport.progress_bar_bg._width = mc.transport.ico_sound._x - mc.transport.progress_bar_bg._x - (BUTTON_MARGIN*2);
    } else {
      mc.transport.progress_bar_bg._width = mc.transport.ico_sound_muted._x - mc.transport.progress_bar_bg._x - (BUTTON_MARGIN*2);
    }
    mc.transport.progress_bar_load._x = mc.transport.progress_bar_position._x = mc.transport.progress_bar_bg._x + 1;
    mc.transport._y = Stage.height - mc.transport._height;
    mc.transport._x = 0;
    update_cue_markers();
  }
  private function update_progress_bar(){
    mc.transport.progress_bar_position._width = 0;
    mc.transport.progress_bar_position._width = ((ns.time / metadata.duration) * mc.transport.progress_bar_bg._width) - 2;
    mc.transport.progress_bar_load._width = ((ns.bytesLoaded / ns.bytesTotal) * mc.transport.progress_bar_bg._width) - 2;
  }
  function toggle_fullscreen(){
    Stage.fullScreenSourceRect = new Rectangle(0,0,Stage.width,Stage.height);
    Stage.addListener(this);
    Stage.displayState == 'fullScreen' ? Stage.displayState = 'normal' : Stage.displayState = 'fullScreen';
  }
  private function make_button(btn:MovieClip,action:Function){
    btn.onRelease = action;
    btn.onRollOver = Delegate.create(this,on_rollover_btn,btn);
    btn.onRollOut = Delegate.create(this,on_rollout_btn,btn);
  }
  private function show_play_button(){
    mc.transport.attachMovie('btn_play','btn_play',LEVEL_BTN_PLAY,{_x:BUTTON_MARGIN, _y:BUTTON_MARGIN});
    make_button(mc.transport.btn_play,Delegate.create(this,toggle_play));
  }
  private function show_pause_button(){
    mc.transport.attachMovie('btn_pause','btn_pause',LEVEL_BTN_PLAY,{_x:BUTTON_MARGIN, _y:BUTTON_MARGIN});
    make_button(mc.transport.btn_pause,Delegate.create(this,toggle_play));
  }
  function display_message(txt:String){
    mc.createEmptyMovieClip('msg',LEVEL_MESSAGE);
    mc.msg.createTextField('msg_txt',200,5,5,200,50);
    mc.msg.msg_txt.embedFonts = true;
    mc.msg.msg_txt.wordWrap = true;
    mc.msg.msg_txt.autoSize = true;
    mc.msg.msg_txt.setNewTextFormat(Styles.txt_bold_white);
    mc.msg.msg_txt.text = txt;
    mc.msg.createEmptyMovieClip('bg',100);
    mc.msg.bg.beginFill(0x000000,70);
    mc.msg.bg.lineTo(mc.msg.msg_txt._width + 10,0);
    mc.msg.bg.lineTo(mc.msg.msg_txt._width + 10,mc.msg.msg_txt._height + 10);
    mc.msg.bg.lineTo(0,mc.msg.msg_txt._height + 10);
    mc.msg.bg.lineTo(0,0);
    mc.msg.bg.endFill();
    DropShadow.create(mc.msg.msg_txt);
    center_on_stage(mc.msg);
  }
  function hide_message(){
    mc.msg.removeMovieClip();
  }


  // Audio
  function mute(){
    audio_muted = true;
    mc.transport.attachMovie('ico_sound_muted','ico_sound_muted',LEVEL_ICO_SOUND);
    make_button(mc.transport.ico_sound_muted,Delegate.create(this,toggle_audio));
    audio.setVolume(0);
  }
  function unmute(){
    audio_muted = false;
    mc.transport.attachMovie('ico_sound','ico_sound',LEVEL_ICO_SOUND);
    make_button(mc.transport.ico_sound,Delegate.create(this,toggle_audio));
    audio.setVolume(100);
  }
  function toggle_audio(){
    if(audio_muted){
      unmute();
    } else {
      mute();
    }
    redraw_transport();
  }


  // Placeholder image
  function load_placeholder(uri:String){
    mc.createEmptyMovieClip('placeholder',LEVEL_PLACEHOLDER);
    mc.placeholder.createEmptyMovieClip('img',100);
    var loader:MovieClipLoader = new MovieClipLoader();
    loader.onLoadInit = Delegate.create(this,show_placeholder);
    loader.loadClip(uri,mc.placeholder.img);
    redraw_transport();
  }
  function hide_placeholder(){
    mc.placeholder._visible = false;
  }
  function show_placeholder(){
    center_on_stage(mc.placeholder);
    mc.placeholder._visible = true;
    mc.placeholder.onRelease = Delegate.create(this,toggle_play);
  }
  function center_on_stage(mc:MovieClip){
    mc._x = Math.floor(Stage.width / 2 - mc._width / 2)
    mc._y = Math.floor(Stage.height / 2 - mc._height / 2)
  }

  // Watermark
  function load_watermark(uri:String){
    mc.createEmptyMovieClip('watermark',LEVEL_WATERMARK);
    mc.watermark.createEmptyMovieClip('img',100);
    var loader:MovieClipLoader = new MovieClipLoader();
    loader.onLoadInit = Delegate.create(this,position_watermark);
    loader.loadClip(uri,mc.watermark.img);
  }
  function position_watermark(){
    mc.watermark._x = Stage.width - mc.watermark._width - (BUTTON_MARGIN * 3);
    mc.watermark._y = Stage.height - mc.watermark._height - (BUTTON_MARGIN * 3);
  }

  // Video Markers
  function update_cue_markers(){
    for (var i:Number=0 ; i < cue_markers.length; i++){
      var current_cue:Object = cue_markers[i];
      add_marker(current_cue.id,current_cue.name,current_cue.time);
    }
  }
  function add_marker(id:Number,name:String,time:Number){
    var marker:MovieClip = mc.transport.attachMovie('cue_marker','cue_marker_'+id,LEVEL_CUE_MARKERS + id,{_x: time_to_position(time)});
    marker.onRelease = Delegate.create(this,seek_to,time);
    marker.onRollOver = Delegate.create(this,on_cue_marker_rollover,name);
    marker.onRollOut = Delegate.create(this,on_cue_marker_rollout);
  }
  private function time_to_position(time:Number):Number{
    var left:Number = mc.transport.progress_bar_bg._x;
    var max_width:Number = mc.transport.progress_bar_bg._width;
    return Math.floor((time / metadata.duration) * max_width + left - 3);
  }
  private function position_to_time(x_pos:Number):Number{
    var max_width:Number = mc.transport.progress_bar_bg._width;
    return (x_pos / max_width) * metadata.duration;
  }
  private function time_to_bytes(seconds:Number):Number{
    return seconds / metadata.duration * ns.bytesTotal;
  }
  private function bytes_to_time(bytes:Number):Number{
    return bytes / ns.bytesTotal * metadata.duration;
  }
}