class TransitionController < ApplicationController
  skip_before_action :verify_authenticity_token

  # POST /perform/:uuid
  def perform
    state = Machine.find_by!(uuid: params[:uuid]).machine_state
    state.brew_button = params.dig(:current_state, :brew_button)
    state.strength_button = params.dig(:current_state, :strength_button)
    state.save!

    temperature_update = params.dig(:current_state, :temperature)
    state.add_temperature!(temperature_update) unless temperature_update.nil?

    print params[:actions_performed]
    params[:actions_performed].each do |action_performed|
      MachineAction.
          find_by(uuid: action_performed[:uuid]).
          update!(status: action_performed[:status])
    end

    render status: :ok, json: {}
  end

  # GET /queued/:uuid
  def queued
    machine = Machine.find_by!(uuid: params[:uuid])
    state = machine.machine_state
    queued_actions = machine.machine_actions.queued || []

    render status: :ok, json: {
        current_state: {
            brew_button: state.brew_button,
            strength_button: state.strength_button,
            temperature: state.machine_temperatures.last.degree
        },
        queued_actions: queued_actions.map do |queued_action|
          {
              uuid: queued_action[:uuid],
              status: queued_action[:status],
              action: queued_action[:action]
          }
        end
    }
  end

  # GET /temperatures/:uuid
  def temperatures
    machine = Machine.find_by!(uuid: params[:uuid])
    state = machine.machine_state

    render status: :ok, json: {
        current_state: {
            temperatures: state.machine_temperatures.ordered
        }
    }
  end

  # POST /play
  def play
    audio_device = AudioDevice.first
    PlayAlarmMusicJob.
        set(wait_until: params[:scheduled_at]&.to_datetime&.in_time_zone).
        perform_later(audio_device, params[:file_url])

    render status: :created, json: {}
  end

  # POST /schedule
  def schedule
    scheduling = Schedule.create!(
        admin_user: AdminUser.first,
        play_on_audio_device: params[:play_on_audio_device],
        play_on_phone: params[:play_on_phone],
        scheduled_at: params[:scheduled_at])
    PerformScheduleJob.set(wait_until: scheduling.scheduled_at).
        perform_later(scheduling)

    render status: :created, json: {}
  end

  # POST /brew/:uuid
  def brew
    machine = Machine.find_by!(uuid: params[:uuid])
    MachineAction.create!(machine: machine, action: 'brew')

    render status: :created, json: {}
  end

  # POST /switch_brew/:uuid
  def switch_brew
    machine = Machine.find_by!(uuid: params[:uuid])
    state = machine.machine_state
    render status: :not_modified, json: {} if params[:set_strength] == state.brew_button

    MachineAction.create!(machine: machine, action: 'switch_brew')
    render status: :created, json: {}
  end

  # POST /sms_hook
  def sms_hook
    message = params[:Body]
    matches = message.match(/(schedule|alarm).* ([0-9]?[0-9]:?[0-9]?[0-9]?) ?(am|pm).* (today|tonight|tomorrow)/i)

    if matches.nil?
      twiml = Twilio::TwiML::MessagingResponse.new do |r|
        r.message(body: "Sorry, I don't understand you. Try saying something like: Schedule alarm for 6:20am tomorrow")
      end
      return render status: :ok, xml: twiml.to_xml
    end

    action, time, meridiem, date = matches.captures
    schedule_datetime = "#{time}#{meridiem}".to_datetime.in_time_zone
    print time
    print date
    if date == 'tommorow'
      schedule_datetime = schedule_datetime.tomorrow
    end

    twiml = Twilio::TwiML::MessagingResponse.new do |r|
      r.message(body: "Okay, I have scheduled your coffee to be ready at #{schedule_datetime}.")
    end

    scheduling = Schedule.create!(
        admin_user: AdminUser.first,
        play_on_audio_device: true,
        play_on_phone: true,
        scheduled_at: schedule_datetime)

    BrewCoffeeJob.set(wait_until: schedule_datetime - 45.seconds).perform_later
    PerformScheduleJob.set(wait_until: schedule_datetime).
        perform_later(scheduling)

    render status: :ok, xml: twiml.to_xml
  end
end
