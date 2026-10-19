import Foundation

/// A compact, quarter-hour rotation keeps the Today entry point welcoming
/// without changing while the person is reading it.
enum TodayGreeting {
  private static let messages = [
    "记录每一份投入，让努力清晰可见",
    "今天的每一步，都在向前",
    "让正在发生的，沉淀成你的力量",
    "你只管前行，Dayday 记下每一次抵达",
    "每一次投入，都值得留下来",
    "让时间见证你的步伐",
    "把今天走过的路，汇成明天的底气",
    "当你专注向前，Dayday 替你守住轨迹",
    "不必回头寻找，今天都在这里",
    "一天一页，慢慢长成你想去的地方",
    "每一次开始，都算数",
    "把点滴留住，把方向走稳",
    "安静记录，坚定向前",
    "慢慢做事，稳稳抵达",
    "让日常有据，让成长可见",
    "你正在做的，会留下痕迹"
  ]

  static func message(for date: Date) -> String {
    let quarterHour = Int(date.timeIntervalSinceReferenceDate / (15 * 60))
    return messages[quarterHour % messages.count]
  }
}
