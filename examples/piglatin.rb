#!/usr/bin/env ruby

require 'sockd'

Sockd.run 'piglatin' do |sockd|

  sockd.options = {
    pid_path: '/tmp/piglatin.pid',
    host: '0.0.0.0',
    port: 23456
  }

  sockd.handle do |message, socket|

    # translate a message into pig-latin
    translated = message.chomp.split(' ').map do |str|
      alpha = ('a'..'z').to_a
      vowels = %w[a e i o u]
      consonants = alpha - vowels

      if vowels.include?(str[0])
        str + 'ay'
      elsif consonants.include?(str[0]) && consonants.include?(str[1])
        str[2..-1] + str[0..1] + 'ay'
      elsif consonants.include?(str[0])
        str[1..-1] + str[0] + 'ay'
      else
        str # return unchanged
      end
    end.join(' ')

    # log and return the translation
    sockd.log "received message: #{message}"
    sockd.log "returning pig latin: #{translated}"
    socket.print translated + "\r\n"
  end
end
