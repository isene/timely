module Timely
  module UI
    module Panes
      def setup_display
        require 'io/console'
        if IO.console
          @h, @w = IO.console.winsize
        else
          @h = ENV['LINES']&.to_i || 24
          @w = ENV['COLUMNS']&.to_i || 80
        end
      end

      def create_panes
        @panes = {}

        # Layout: info(1) + top(months, fixed 9) + mid(week, flexible) + bottom(details) + status(1)
        # Top pane: 1 blank row + 8 month rows = 9
        top_h = 9
        bottom_h = (@h * 0.2).to_i
        bottom_h = [bottom_h, 5].max
        mid_h = @h - 2 - top_h - bottom_h  # 2 = info + status
        mid_h = [mid_h, 4].max

        # Adjust if overflow
        if 2 + top_h + mid_h + bottom_h > @h
          bottom_h = @h - 2 - top_h - mid_h
          bottom_h = [bottom_h, 3].max
        end

        info_bg = @config ? @config.get('colors.info_bg', 235) : 235
        status_bg = @config ? @config.get('colors.status_bg', 235) : 235
        @panes[:info] = Rcurses::Pane.new(1, 1, @w, 1, 255, info_bg)
        @panes[:top] = Rcurses::Pane.new(1, 2, @w, top_h)
        @panes[:mid] = Rcurses::Pane.new(1, 2 + top_h, @w, mid_h)
        @panes[:bottom] = Rcurses::Pane.new(1, 2 + top_h + mid_h, @w, bottom_h)
        @panes[:status] = Rcurses::Pane.new(1, @h, @w, 1, 252, status_bg)

        @panes.each_value do |p|
          p.border = false
          p.scroll = false
        end
        @panes[:bottom].scroll = true  # Enable scroll indicators for event details
      end
    end
  end
end
