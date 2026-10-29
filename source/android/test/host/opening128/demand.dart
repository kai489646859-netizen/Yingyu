// Complete production stream callbacks. Native state is updated before stream delivery.
class State {bool playing=false,buffering=false;}
class Player {final state=State();}
class Disc {bool hint=false;void setBuffering(bool v){hint=v;}}
class Clock {Duration elapsed=Duration.zero;}
class Recovery {void playbackChanged({required Duration now,required bool playing}){}}
class Audio {void suspend(){}}
class Harness {bool _opening=false;set opening(bool v)=>_opening=v;
final player=Player();Disc? _disc=Disc();final _runtimeClock=Clock();final _dolbyRecovery=Recovery();final _audioDecode=Audio();
bool get hint=>_disc?.hint??false;void ordinary()=>_disc=null;void emit(){}
// This fixture covers disc demand only. Ordinary recovery is tested separately.
void _scheduleStarvationRecovery(bool buffering){}
void buffering(bool value){player.state.buffering=value;void callback(bool buffering){
        if (buffering) _audioDecode.suspend();
        // Opening/paused initialization is not proof of network starvation.
        _disc?.setBuffering(buffering && !_opening && player.state.playing);
        _scheduleStarvationRecovery(buffering);
        emit();}callback(value);}
void playing(bool value){player.state.playing=value;void callback(bool playing){
        _dolbyRecovery.playbackChanged(
          now: _runtimeClock.elapsed,
          playing: playing,
        );
        _disc?.setBuffering(playing && !_opening && player.state.buffering);
        emit();}callback(value);}}
