require 'sinatra/json'
require 'active_support/json'
require 'active_support/time'
require_relative 'db'

Time.zone = 'UTC'

class App < Sinatra::Base
  enable :logging

  set :session_secret, 'tagomoris'
  set :sessions, key: 'session_isucon2021_prior', expire_after: 3600
  set :show_exceptions, false
  set :public_folder, './public'
  set :json_encoder, ActiveSupport::JSON

  helpers do
    def db
      DB.connection
    end

    def transaction(name = :default, &block)
      DB.transaction(name, &block)
    end

    def generate_id(table, tx)
      id = ULID.generate
      while tx.xquery("SELECT 1 FROM `#{table}` WHERE `id` = ? LIMIT 1", id).first
        id = ULID.generate
      end
      id
    end

    def required_login!
      halt(401, JSON.generate(error: 'login required')) if current_user.nil?
    end

    def required_staff_login!
      halt(401, JSON.generate(error: 'login required')) if current_user.nil? || !current_user[:staff]
    end

    def current_user
      if session[:user].blank?
        user = db.xquery('SELECT * FROM `users` WHERE `id` = ? LIMIT 1', session[:user_id]).first
        session[:user] = user
      end
      session[:user]
    end

    def get_reservations(schedule)
      current = current_user
      # TODO: user N+1対策する
      query = <<~EOS
        SELECT
          r.id as reservation_id,
          r.schedule_id,
          r.user_id,
          r.created_at AS reservation_created_at,
          u.email,
          u.nickname,
          u.created_at AS user_created_at
        FROM reservations AS r
        INNER JOIN users AS u ON u.id = r.user_id
        WHERE schedule_id = ?
      EOS
      reservations = db.xquery(query, schedule[:id]).map do |r|
        reservation = {}
        reservation[:id] = r[:reservation_id].to_s
        reservation[:schedule_id] = r[:schedule_id].to_s
        reservation[:user_id] = r[:user_id].to_s
        reservation[:created_at] = r[:reservation_created_at]
        user = {}
        user[:id] = r[:user_id].to_s
        if current.present? && (current[:id] == r[:user_id] || current[:staff])
          user[:email] = r[:email]
        else
          user[:email] = ''
        end
        user[:nickname] = r[:nickname]
        user[:created_at] = r[:user_created_at]
        reservation[:user] = user
        reservation
      end
      schedule[:reservations] = reservations
      schedule[:reserved] = reservations.size
    end

    def get_user(id)
      user = db.xquery('SELECT * FROM `users` WHERE `id` = ? LIMIT 1', id).first
      user[:email] = '' if !current_user || !current_user[:staff]
      user
    end
  end

  error do
    err = env['sinatra.error']
    $stderr.puts err.full_message
    halt 500, JSON.generate(error: err.message)
  end

  post '/initialize' do
    transaction do |tx|
      tx.query('TRUNCATE `reservations`')
      tx.query('TRUNCATE `schedules`')
      tx.query('TRUNCATE `users`')

      tx.xquery('INSERT INTO `users` (`email`, `nickname`, `staff`, `created_at`) VALUES (?, ?, true, NOW(6))', 'isucon2021_prior@isucon.net', 'isucon')
    end

    json(language: 'ruby')
  end

  get '/api/session' do
    json(current_user)
  end

  post '/api/signup' do
    id = ''
    nickname = ''

    user = transaction do |tx|
      email = params[:email]
      nickname = params[:nickname]
      tx.xquery('INSERT INTO `users` (`email`, `nickname`, `created_at`) VALUES (?, ?, NOW(6))', email, nickname)
      user = tx.xquery('SELECT `id`, `created_at` FROM `users` WHERE `id` = LAST_INSERT_ID() LIMIT 1').first

      { id: user[:id].to_s, email: email, nickname: nickname, created_at: user[:created_at] }
    end

    json(user)
  end

  post '/api/login' do
    email = params[:email]

    user = db.xquery('SELECT `id`, `nickname` FROM `users` WHERE `email` = ? LIMIT 1', email).first

    if user
      session[:user_id] = user[:id]
      json({ id: current_user[:id].to_s, email: current_user[:email], nickname: current_user[:nickname], created_at: current_user[:created_at] })
    else
      session[:user_id] = nil
      halt 403, JSON.generate({ error: 'login failed' })
    end
  end

  post '/api/schedules' do
    required_staff_login!

    transaction do |tx|
      title = params[:title].to_s
      capacity = params[:capacity].to_i

      tx.xquery('INSERT INTO `schedules` (`title`, `capacity`, `created_at`) VALUES (?, ?, NOW(6))', title, capacity)
      schedule = tx.xquery('SELECT `id`, `created_at` FROM `schedules` WHERE `id` = LAST_INSERT_ID()').first

      json({ id: schedule[:id].to_s, title: title, capacity: capacity, created_at: schedule[:created_at] })
    end
  end

  post '/api/reservations' do
    required_login!

    transaction do |tx|
      schedule_id = params[:schedule_id].to_i
      user_id = current_user[:id].to_i

      halt(403, JSON.generate(error: 'schedule not found')) if tx.xquery('SELECT 1 FROM `schedules` WHERE `id` = ? LIMIT 1 FOR UPDATE', schedule_id).first.nil?
      halt(403, JSON.generate(error: 'user not found')) unless tx.xquery('SELECT 1 FROM `users` WHERE `id` = ? LIMIT 1', user_id).first
      halt(403, JSON.generate(error: 'already taken')) if tx.xquery('SELECT 1 FROM `reservations` WHERE `schedule_id` = ? AND `user_id` = ? LIMIT 1', schedule_id, user_id).first

      capacity = tx.xquery('SELECT `capacity` FROM `schedules` WHERE `id` = ? LIMIT 1', schedule_id).first[:capacity]
      reserved = 0
      # TODO: N+1?
      tx.xquery('SELECT * FROM `reservations` WHERE `schedule_id` = ?', schedule_id).each do
        reserved += 1
      end

      halt(403, JSON.generate(error: 'capacity is already full')) if reserved >= capacity

      tx.xquery('INSERT INTO `reservations` (`schedule_id`, `user_id`, `created_at`) VALUES (?, ?, NOW(6))', schedule_id, user_id)
      reservation = tx.xquery('SELECT `id`, `created_at` FROM `reservations` WHERE `id` = LAST_INSERT_ID()').first

      json({ id: reservation[:id].to_s, schedule_id: schedule_id, user_id: user_id, created_at: reservation[:created_at]})
    end
  end

  get '/api/schedules' do
    schedules = db.xquery('SELECT s.*, count(r.id) AS reserved FROM `schedules` AS s LEFT JOIN `reservations` AS r ON `r`.`schedule_id` = `s`.`id` GROUP BY s.id ORDER BY `s`.`id` DESC');

    schedules.map do |schedule|
      schedule[:id] = schedule[:id].to_s
    end

    json(schedules.to_a)
  end

  get '/api/schedules/:id' do
    id = params[:id].to_i
    schedule = db.xquery('SELECT * FROM `schedules` WHERE id = ? LIMIT 1', id).first
    halt(404, {}) unless schedule
    get_reservations(schedule)
    schedule[:id] = schedule[:id].to_s
    json(schedule)
  end

  get '*' do
    File.read(File.join('public', 'index.html'))
  end
end
