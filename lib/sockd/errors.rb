module Sockd

  class SockdError < StandardError
  end

  class OptionParserError < SockdError
  end

  class BadCommandError < SockdError
  end

  class ProcError < SockdError
  end

end
