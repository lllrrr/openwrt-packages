from pathlib import Path
import sys
import time
import unittest


def row(symbol, seconds, description):
    duration = f'{seconds:.2f}s'
    return f'{symbol} {duration:>12}  {description}'


class ReportStream:
    def __init__(self, stream):
        self.stream = stream

    def write(self, text):
        return self.stream.write(text)

    def writeln(self, text=''):
        self.stream.write(text + '\n')
        self.stream.flush()

    def __getattr__(self, name):
        return getattr(self.stream, name)


class ChineseResult(unittest.TextTestResult):
    def startTest(self, test):
        super().startTest(test)
        self.started = time.perf_counter()
        self.before = (len(self.failures) + len(self.errors) + len(self.unexpectedSuccesses),
                       len(self.skipped), len(self.expectedFailures))

    def stopTest(self, test):
        failed = len(self.failures) + len(self.errors) + len(self.unexpectedSuccesses) > self.before[0]
        skipped = len(self.skipped) > self.before[1]
        expected = len(self.expectedFailures) > self.before[2]
        suffix = ' [跳过]' if skipped else ' [预期失败]' if expected else ''
        self.stream.writeln(row('✘' if failed else '﹣' if skipped else '✔',
                                time.perf_counter() - self.started, self.getDescription(test) + suffix))
        super().stopTest(test)

    def getDescription(self, test):
        description = test.shortDescription() or str(test)
        # 失败的子用例保留参数, 便于定位具体的标签或校验值.
        parameters = getattr(test, 'params', None)
        if parameters:
            description += f' {dict(parameters)!r}'
        return description


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.discover(str(Path(__file__).resolve().parent), pattern='test_*.py')
    result = ChineseResult(ReportStream(sys.stdout), descriptions=True, verbosity=0)
    started = time.perf_counter()
    result.startTestRun()
    try:
        suite.run(result)
    finally:
        result.stopTestRun()
    # 保留 unittest 收集的完整失败详情, 自定义报告不改变测试退出状态.
    result.printErrors()
    summary = (f'Python 测试完成: 共 {result.testsRun} 项, '
               f'失败 {len(result.failures)} 项, 错误 {len(result.errors)} 项')
    for label, entries in [('跳过', result.skipped), ('预期失败', result.expectedFailures),
                           ('非预期通过', result.unexpectedSuccesses)]:
        if entries:
            summary += f', {label} {len(entries)} 项'
    result.stream.writeln(row('✔' if result.wasSuccessful() else '✘', time.perf_counter() - started, summary))
    sys.exit(0 if result.wasSuccessful() else 1)
