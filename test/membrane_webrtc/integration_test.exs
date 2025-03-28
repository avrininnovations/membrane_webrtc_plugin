defmodule Membrane.WebRTC.IntegrationTest do
  # Tests are split into submodules so that they run concurrently
  # credo:disable-for-this-file Credo.Check.Readability.Specs

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad, as: Pad

  alias Membrane.Testing
  alias Membrane.WebRTC
  alias Membrane.WebRTC.Signaling

  defmodule KeyframeTestSource do
    use Membrane.Source

    def_output_pad :output, flow_control: :manual, accepted_format: _any

    def_options stream_format: [spec: Membrane.StreamFormat.t()]

    @impl true
    def handle_playing(_ctx, state) do
      buffers =
        Bunch.Enum.repeated(
          %Membrane.Buffer{payload: "mock" <> <<0::1000*8>>, pts: 0, dts: 0},
          10
        )

      {[stream_format: {:output, state.stream_format}, buffer: {:output, buffers}], state}
    end

    @impl true
    def handle_demand(:output, _size, _unit, _ctx, state) do
      {[], state}
    end

    @impl true
    def handle_event(:output, %Membrane.KeyframeRequestEvent{}, _ctx, state) do
      {[notify_parent: :keyframe_requested], state}
    end

    @impl true
    def handle_event(:output, _event, _ctx, state) do
      {[], state}
    end
  end

  defmodule KeyframeTestSink do
    use Membrane.Sink

    def_input_pad :input, accepted_format: _any

    @impl true
    def handle_playing(_ctx, state) do
      {[notify_parent: :playing], state}
    end

    @impl true
    def handle_buffer(:input, buffer, _ctx, state) do
      {[notify_parent: {:buffer, buffer}], state}
    end

    @impl true
    def handle_parent_notification(:request_keyframe, _ctx, state) do
      {[event: {:input, %Membrane.KeyframeRequestEvent{}}], state}
    end
  end

  defmodule Utils do
    import ExUnit.Assertions

    def fixture_processing_timeout, do: 30_000

    def prepare_input(pipeline, opts) do
      demuxer_name = {:demuxer, make_ref()}

      Testing.Pipeline.execute_actions(pipeline,
        spec:
          child(%Membrane.File.Source{location: "test/fixtures/input_bbb.mkv"})
          |> child(demuxer_name, Membrane.Matroska.Demuxer)
      )

      assert_pipeline_notified(
        pipeline,
        demuxer_name,
        {:new_track, {mkv_video_id, %{codec: :vp8}}}
      )

      assert_pipeline_notified(
        pipeline,
        demuxer_name,
        {:new_track, {mkv_audio_id, %{codec: :opus}}}
      )

      webrtc = if opts[:webrtc], do: [child(:webrtc, opts[:webrtc])], else: []

      Testing.Pipeline.execute_actions(pipeline,
        spec: [
          webrtc,
          get_child(demuxer_name)
          |> via_out(Pad.ref(:output, mkv_audio_id))
          |> child(Membrane.Realtimer)
          |> via_in(Pad.ref(:input, opts[:webrtc_audio_id] || :audio), options: [kind: :audio])
          |> get_child(:webrtc),
          get_child(demuxer_name)
          |> via_out(Pad.ref(:output, mkv_video_id))
          |> child(Membrane.Realtimer)
          |> via_in(Pad.ref(:input, opts[:webrtc_video_id] || :video), options: [kind: :video])
          |> get_child(:webrtc)
        ]
      )
    end

    def prepare_output(pipeline, tmp_dir, opts) do
      webrtc = if opts[:webrtc], do: [child(:webrtc, opts[:webrtc])], else: []
      id = opts[:output_id] || ""

      Testing.Pipeline.execute_actions(pipeline,
        spec: [
          webrtc,
          get_child(:webrtc)
          |> via_out(Pad.ref(:output, opts[:webrtc_audio_id] || :audio), options: [kind: :audio])
          |> child(Membrane.Opus.Parser)
          |> child({:audio_sink, id}, %Membrane.File.Sink{location: "#{tmp_dir}/out_audio#{id}"}),
          get_child(:webrtc)
          |> via_out(Pad.ref(:output, opts[:webrtc_video_id] || :video), options: [kind: :video])
          |> child({:video_sink, id}, %Membrane.File.Sink{location: "#{tmp_dir}/out_video#{id}"})
        ]
      )
    end

    def run_keyframe_testing_pipelines(opts \\ []) do
      signaling = Signaling.new()

      send_pipeline = Testing.Pipeline.start_link_supervised!()

      video_src = %KeyframeTestSource{
        stream_format: %Membrane.RemoteStream{content_format: Membrane.VP8, type: :packetized}
      }

      audio_src = %KeyframeTestSource{stream_format: %Membrane.Opus{channels: 2}}

      Testing.Pipeline.execute_actions(send_pipeline,
        spec: [
          child(:vid1, video_src)
          |> via_in(:input, options: [kind: :video])
          |> get_child(:webrtc),
          child(:vid2, video_src)
          |> via_in(:input, options: [kind: :video])
          |> get_child(:webrtc),
          child(:audio, audio_src)
          |> via_in(:input, options: [kind: :audio])
          |> get_child(:webrtc),
          child(:webrtc, %WebRTC.Sink{signaling: signaling, tracks: [:audio, :video, :video]})
        ]
      )

      receive_pipeline = Testing.Pipeline.start_link_supervised!()

      Testing.Pipeline.execute_actions(receive_pipeline,
        spec: [
          child(:webrtc, %WebRTC.Source{
            signaling: signaling,
            keyframe_interval: opts[:keyframe_interval]
          }),
          get_child(:webrtc)
          |> via_out(:output, options: [kind: :video])
          |> child(:vid1, KeyframeTestSink),
          get_child(:webrtc)
          |> via_out(:output, options: [kind: :video])
          |> child(:vid2, KeyframeTestSink),
          get_child(:webrtc)
          |> via_out(:output, options: [kind: :audio])
          |> child(:audio, KeyframeTestSink)
        ]
      )

      assert_pipeline_notified(receive_pipeline, :vid1, {:buffer, _buffer}, 5_000)
      assert_pipeline_notified(receive_pipeline, :vid2, {:buffer, _buffer}, 5_000)
      assert_pipeline_notified(receive_pipeline, :audio, {:buffer, _buffer}, 5_000)

      {send_pipeline, receive_pipeline}
    end
  end

  defmodule SendRecv do
    use ExUnit.Case, async: true

    import Membrane.Testing.Assertions
    import Utils

    @tag :tmp_dir
    test "send and receive a file", %{tmp_dir: tmp_dir} do
      signaling = Signaling.new()
      send_pipeline = Testing.Pipeline.start_link_supervised!()

      prepare_input(send_pipeline,
        webrtc: %WebRTC.Sink{signaling: signaling, video_codec: [:vp8, :h264]}
      )

      receive_pipeline = Testing.Pipeline.start_link_supervised!()

      prepare_output(receive_pipeline, tmp_dir, webrtc: %WebRTC.Source{signaling: signaling})

      [send_pipeline, receive_pipeline]
      |> Enum.each(fn pipeline ->
        assert_pipeline_notified(pipeline, :webrtc, {:negotiated_video_codecs, [:vp8]})
      end)

      assert_pipeline_notified(
        send_pipeline,
        :webrtc,
        {:end_of_stream, :audio},
        fixture_processing_timeout()
      )

      assert_pipeline_notified(send_pipeline, :webrtc, {:end_of_stream, :video}, 1_000)
      # Time for the stream to arrive to the receiver
      Process.sleep(200)
      Testing.Pipeline.terminate(send_pipeline)
      assert_end_of_stream(receive_pipeline, {:audio_sink, _id}, :input, 1_000)
      assert_end_of_stream(receive_pipeline, {:video_sink, _id}, :input, 1_000)
      Testing.Pipeline.terminate(receive_pipeline)
      assert File.read!("#{tmp_dir}/out_audio") == File.read!("test/fixtures/ref_audio")
      assert File.read!("#{tmp_dir}/out_video") == File.read!("test/fixtures/ref_video")
    end
  end

  defmodule DynamicTracks do
    use ExUnit.Case, async: true

    import Utils

    @tag :tmp_dir
    test "dynamically add new tracks", %{tmp_dir: tmp_dir} do
      signaling = Signaling.new()

      send_pipeline = Testing.Pipeline.start_link_supervised!()
      prepare_input(send_pipeline, webrtc: %WebRTC.Sink{signaling: signaling})

      receive_pipeline = Testing.Pipeline.start_link_supervised!()

      prepare_output(receive_pipeline, tmp_dir,
        output_id: 1,
        webrtc: %WebRTC.Source{signaling: signaling}
      )

      assert_start_of_stream(receive_pipeline, {:audio_sink, 1}, :input, 5_000)
      assert_start_of_stream(receive_pipeline, {:video_sink, 1}, :input, 5_000)

      Process.sleep(1500)

      Testing.Pipeline.notify_child(send_pipeline, :webrtc, {:add_tracks, [:audio, :video]})

      assert_pipeline_notified(receive_pipeline, :webrtc, {:new_tracks, tracks})

      [send_pipeline, receive_pipeline]
      |> Enum.each(fn pipeline ->
        assert_pipeline_notified(pipeline, :webrtc, {:negotiated_video_codecs, [:vp8]})
      end)

      assert [%{kind: :audio, id: audio_id}, %{kind: :video, id: video_id}] =
               Enum.sort_by(tracks, & &1.kind)

      prepare_output(receive_pipeline, tmp_dir,
        output_id: 2,
        webrtc_audio_id: audio_id,
        webrtc_video_id: video_id
      )

      assert_pipeline_notified(send_pipeline, :webrtc, {:new_tracks, tracks})

      assert [%{kind: :audio, id: audio_id}, %{kind: :video, id: video_id}] =
               Enum.sort_by(tracks, & &1.kind)

      prepare_input(send_pipeline, webrtc_audio_id: audio_id, webrtc_video_id: video_id)

      assert_pipeline_notified(
        send_pipeline,
        :webrtc,
        {:end_of_stream, :audio},
        fixture_processing_timeout()
      )

      assert_pipeline_notified(send_pipeline, :webrtc, {:end_of_stream, :video}, 1_000)
      assert_pipeline_notified(send_pipeline, :webrtc, {:end_of_stream, ^audio_id}, 3_000)
      assert_pipeline_notified(send_pipeline, :webrtc, {:end_of_stream, ^video_id}, 1_000)
      # Time for the stream to arrive to the receiver
      Process.sleep(200)
      Testing.Pipeline.terminate(send_pipeline)

      Enum.each([audio_sink: 1, video_sink: 1, audio_sink: 2, video_sink: 2], fn element ->
        assert_end_of_stream(receive_pipeline, ^element, :input, 1_000)
      end)

      Testing.Pipeline.terminate(receive_pipeline)
      assert File.read!("#{tmp_dir}/out_audio1") == File.read!("test/fixtures/ref_audio")
      assert File.read!("#{tmp_dir}/out_video1") == File.read!("test/fixtures/ref_video")
      assert File.read!("#{tmp_dir}/out_audio2") == File.read!("test/fixtures/ref_audio")
      assert File.read!("#{tmp_dir}/out_video2") == File.read!("test/fixtures/ref_video")
    end
  end

  defmodule KeyframeRequestEvents do
    use ExUnit.Case, async: true

    import Utils

    test "keyframe request events" do
      {send_pipeline, receive_pipeline} = run_keyframe_testing_pipelines()

      Testing.Pipeline.notify_child(receive_pipeline, :vid1, :request_keyframe)
      Testing.Pipeline.notify_child(receive_pipeline, :vid2, :request_keyframe)
      Testing.Pipeline.notify_child(receive_pipeline, :audio, :request_keyframe)

      assert_pipeline_notified(send_pipeline, :vid1, :keyframe_requested)
      assert_pipeline_notified(send_pipeline, :vid2, :keyframe_requested)
      refute_pipeline_notified(send_pipeline, :vid1, :keyframe_requested)
      refute_pipeline_notified(send_pipeline, :vid2, :keyframe_requested)
      refute_pipeline_notified(send_pipeline, :audio, :keyframe_requested)

      [send_pipeline, receive_pipeline]
      |> Enum.each(fn pipeline ->
        assert_pipeline_notified(pipeline, :webrtc, {:negotiated_video_codecs, [:vp8]})
      end)

      Testing.Pipeline.terminate(send_pipeline)
      Testing.Pipeline.terminate(receive_pipeline)
    end
  end

  defmodule KeyframeInterval do
    use ExUnit.Case, async: true

    import Utils

    test "keyframe request events every time interval" do
      {send_pipeline, receive_pipeline} =
        run_keyframe_testing_pipelines(keyframe_interval: Membrane.Time.seconds(1))

      Enum.each(1..3, fn _i ->
        assert_pipeline_notified(send_pipeline, :vid1, :keyframe_requested)
        assert_pipeline_notified(send_pipeline, :vid2, :keyframe_requested)
        refute_pipeline_notified(send_pipeline, :vid1, :keyframe_requested, 800)
        refute_pipeline_notified(send_pipeline, :vid2, :keyframe_requested, 0)
      end)

      refute_pipeline_notified(send_pipeline, :audio, :keyframe_requested)

      [send_pipeline, receive_pipeline]
      |> Enum.each(fn pipeline ->
        assert_pipeline_notified(pipeline, :webrtc, {:negotiated_video_codecs, [:vp8]})
      end)

      Testing.Pipeline.terminate(send_pipeline)
      Testing.Pipeline.terminate(receive_pipeline)
    end
  end

  defmodule WHIP do
    use ExUnit.Case, async: true

    import Utils

    @tag :target
    @tag :tmp_dir
    test "send and receive a file over WHIP", %{tmp_dir: tmp_dir} do
      send_pipeline = Testing.Pipeline.start_link_supervised!()

      prepare_input(send_pipeline,
        webrtc: %WebRTC.Sink{signaling: {:whip, uri: "http://localhost:6789"}}
      )

      receive_pipeline = Testing.Pipeline.start_link_supervised!()

      prepare_output(receive_pipeline, tmp_dir,
        webrtc: %WebRTC.Source{signaling: {:whip, ip: {127, 0, 0, 1}, port: 6789}}
      )

      [send_pipeline, receive_pipeline]
      |> Enum.each(fn pipeline ->
        assert_pipeline_notified(pipeline, :webrtc, {:negotiated_video_codecs, [:vp8]})
      end)

      assert_pipeline_notified(
        send_pipeline,
        :webrtc,
        {:end_of_stream, :audio},
        fixture_processing_timeout()
      )

      assert_pipeline_notified(send_pipeline, :webrtc, {:end_of_stream, :video}, 1_000)
      # Time for the stream to arrive to the receiver
      Process.sleep(200)
      Testing.Pipeline.terminate(send_pipeline)
      assert_end_of_stream(receive_pipeline, {:audio_sink, _id}, :input, 1_000)
      assert_end_of_stream(receive_pipeline, {:video_sink, _id}, :input, 1_000)
      Testing.Pipeline.terminate(receive_pipeline)
      assert File.read!("#{tmp_dir}/out_audio") == File.read!("test/fixtures/ref_audio")
      assert File.read!("#{tmp_dir}/out_video") == File.read!("test/fixtures/ref_video")
    end
  end

  defmodule CodecsNegotiation do
    use ExUnit.Case, async: true

    import Membrane.Testing.Assertions
    alias Membrane.WebRTC

    describe "codecs negotiation when" do
      [
        %{
          test_title: "both video codecs are allowed but H264 is preferred",
          webrtc_sink_params: [video_codec: [:vp8, :h264]],
          webrtc_source_params: [
            allowed_video_codecs: [:vp8, :h264],
            preferred_video_codec: :h264
          ]
        },
        %{
          test_title: "source prefers VP8 but sink offers only H264",
          webrtc_sink_params: [video_codec: [:h264]],
          webrtc_source_params: [
            allowed_video_codecs: [:vp8, :h264],
            preferred_video_codec: :vp8
          ]
        }
      ]
      |> Enum.map(fn opts ->
        test opts.test_title do
          signaling = Signaling.new()

          webrtc_sink_params = [signaling: signaling] ++ unquote(opts.webrtc_sink_params)
          webrtc_sink = struct!(WebRTC.Sink, webrtc_sink_params)

          webrtc_source_params = [signaling: signaling] ++ unquote(opts.webrtc_source_params)
          webrtc_source = struct!(WebRTC.Source, webrtc_source_params)

          send_pipeline =
            Testing.Pipeline.start_link_supervised!(
              spec:
                child(%Membrane.File.Source{location: "test/fixtures/input_bbb_h264.mkv"})
                |> child(:demuxer, Membrane.Matroska.Demuxer)
            )

          assert_pipeline_notified(
            send_pipeline,
            :demuxer,
            {:new_track, {mkv_video_id, %{codec: :h264}}}
          )

          assert_pipeline_notified(
            send_pipeline,
            :demuxer,
            {:new_track, {mkv_audio_id, %{codec: :opus}}}
          )

          Testing.Pipeline.execute_actions(send_pipeline,
            spec: [
              child(:webrtc_sink, webrtc_sink),
              get_child(:demuxer)
              |> via_out(Pad.ref(:output, mkv_audio_id))
              |> child(Membrane.Realtimer)
              |> via_in(Pad.ref(:input, :audio), options: [kind: :audio])
              |> get_child(:webrtc_sink),
              get_child(:demuxer)
              |> via_out(Pad.ref(:output, mkv_video_id))
              |> child(%Membrane.H264.Parser{
                output_alignment: :nalu,
                output_stream_structure: :annexb
              })
              |> child(Membrane.Realtimer)
              |> via_in(Pad.ref(:input, :video), options: [kind: :video])
              |> get_child(:webrtc_sink)
            ]
          )

          receive_pipeline =
            Testing.Pipeline.start_link_supervised!(
              spec: [
                child(:webrtc_source, webrtc_source)
                |> via_out(Pad.ref(:output, :audio), options: [kind: :audio])
                |> child(Membrane.Debug.Sink),
                get_child(:webrtc_source)
                |> via_out(Pad.ref(:output, :video), options: [kind: :video])
                |> child(Membrane.Debug.Sink)
              ]
            )

          [{send_pipeline, :webrtc_sink}, {receive_pipeline, :webrtc_source}]
          |> Enum.each(fn {pipeline, webrtc_element} ->
            assert_pipeline_notified(
              pipeline,
              webrtc_element,
              {:negotiated_video_codecs, [:h264]}
            )
          end)

          Process.sleep(500)

          [send_pipeline, receive_pipeline]
          |> Enum.each(&Testing.Pipeline.terminate/1)
        end
      end)
    end
  end
end
