namespace :resque do

  desc "Start a Resque worker, each queue will create it's own worker in a separate thread"
  task :work => :setup do
    require 'resque'

    worker = nil
    queues = (ENV['QUEUES'] || ENV['QUEUE']).to_s.split('#').delete_if { |a| a.blank? }
    threads = []
    mqueue = queues.shift
    # we are assuming the application has been deployed with a standard cap recipe.
    base, version = Rails.root.to_s.split('/releases')
    worker_path = base
    # add current to the path to use the symlink used by a standard cap deploy
    # unless the app is deployed to the "current" directory when using cap-git-deploy
    worker_path += '/current' unless Rails.env.development? || worker_path =~ /current/
    Thread.current[:queues] = mqueue
    Thread.current[:path] = worker_path
    mworker = Resque::Worker.new(mqueue)
    mworker.verbose = true #ENV['LOGGING'] || ENV['VERBOSE']
    mworker.very_verbose = true #ENV['VVERBOSE']

    if ENV['PIDFILE']
      File.open(ENV['PIDFILE'], 'w') { |f| f << mworker.pid }
    end

    queues.each do |queue|
      threads << Thread.new do
        begin
          Thread.current[:queues] = queue
          Thread.current[:path] = worker_path
          worker = Resque::Worker.new(queue)
          worker.verbose = ENV['LOGGING'] || ENV['VERBOSE']
          worker.very_verbose = ENV['VVERBOSE']
        rescue Resque::NoQueueError
          abort "set QUEUE env var, e.g. $ QUEUE=critical,high rake resque:work"
        end

        worker.log "Starting worker #{worker}"
        begin
          worker.work(ENV['INTERVAL'] || 5) # interval, will block
        rescue Exception => e
          puts "********** e.message = " + e.message.inspect
          Rails.logger.info "********** e.message = " + e.message.inspect
        end
      end
    end
    threads.each { |thread| thread.join(0.5) }
    mworker.work(ENV['INTERVAL'] || 5) # interval, will block
  end

  desc "Restart all the workers"
  task :restart_workers => :setup do
    require 'resque'
    pid = ''
    queues = ''
    local_ip = Resque.workers.first.local_ip rescue '';
    rake = ENV['RAKE_WITH_OPTS'] || 'rake'
    Resque.workers.sort_by { |w| w.to_s }.each do |worker|
      if local_ip == worker.ip # only restart the workers that are on this server
        if pid != worker.pid
          if RUBY_PLATFORM =~ /java/
            #jruby doesn't trap the -QUIT signal
            #-TERM gracefully kills the main pid and does a -9 on the child if there is one.
            #Since jruby doesn't fork a child, the main worker is gracefully killed.
            system("kill -TERM  #{worker.pid}")
          else
            system("kill -QUIT  #{worker.pid}")
          end
          queues = worker.queues_in_pid.join('#')
          Thread.new(queues) { |queue| system("nohup #{rake} RAILS_ENV=#{Rails.env} QUEUE=#{queue} resque:work") }
          pid = worker.pid
        end
      end
    end
  end

  desc "Gracefully kill a single worker.  If the worker is working, it will finish before shutting down. arg: pid=pid
       This used to be done directly in the cap task, but since workers can now live in multiple apps, we need to send
       the correct signal based on the worker's platform."
  task :quit_worker => :setup do
    if RUBY_PLATFORM =~ /java/
      #jruby doesn't trap the -QUIT signal
      #-TERM gracefully kills the main pid and does a -9 on the child if there is one.
      #Since jruby doesn't fork a child, the main worker is gracefully killed.
      system("kill -TERM  #{ENV['pid']}")
    else
      system("kill -QUIT  #{ENV['pid']}")
    end
  end

  desc "Gracefully kill all the workers.  If the worker is working, it will finish before shutting down."
  task :quit_workers => :setup do
    require 'resque'
    pid = ''
    local_ip = Resque.workers.first.local_ip
    Resque.workers.sort_by { |w| w.to_s }.each do |worker|
      if local_ip == worker.ip # only quit the workers that are on this server
        if pid != worker.pid
          if RUBY_PLATFORM =~ /java/
            #jruby doesn't trap the -QUIT signal
            #-TERM gracefully kills the main pid and does a -9 on the child if there is one.
            #Since jruby doesn't fork a child, the main worker is gracefully killed.
            system("kill -TERM  #{worker.pid}")
          else
            system("kill -QUIT  #{worker.pid}")
          end
          pid = worker.pid
        end
      end
    end
  end

  desc "Kill all rogue workers on all servers.  If the worker is working, it will not finish and the job will go to the Failed queue as a DirtExit. arg: host=ip pid=pid"
  task :kill_workers_with_impunity => :setup do
    require 'resque'
    pid = ''
    local_ip = Resque.workers.first.local_ip
    Resque.workers.sort_by { |w| w.to_s }.each do |worker|
      if local_ip == worker.ip # only kill the pids that are on this server
        if pid != worker.pid # only kill it once
          `kill -9 #{worker.pid}`
          pid = worker.pid
        end
      end
    end
  end

end
