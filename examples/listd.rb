#!/usr/bin/env ruby

$: << File.expand_path(File.dirname(File.realpath(__FILE__)) + '/../lib')
require 'sockd'

Sockd.run 'listd' do |sockd|

  sockd.options = {
    pid_path: '/tmp/listd.pid',
    socket:   '/tmp/listd.sock'
  }

  array = []
  index = 0

  sockd.handle do |message, socket|
    command, *params = message.split(' ')

    response =
      case command
      when 'add'
        array.push(*params)
        sockd.log 'added ' + params.join(' ')
        ''
      when 'remove'
        array.delete(*params)
        sockd.log 'removed ' + params.join(' ')
        index = 0
        ''
      when 'get'
        if array.empty?
          ''
        else
          value = array[index]
          index = (index + 1) % array.size
          value
        end
      when 'list'
        array.join(' ') || ''
      when 'reset'
        array = []
        index = 0
        sockd.log 'list reset'
        ''
      else
        'bad command'
      end

    socket.print response + "\r\n"
  end
end
