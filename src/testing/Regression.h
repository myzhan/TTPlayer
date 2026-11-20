#pragma once
#include <QString>
#include <QTextStream>
// Return -1 when the suite is handled by the original probes.
int runRegressionSuite(const QString &suite, QTextStream &out);
QStringList regressionSuites();
int runQueueCoverage(QTextStream &out);
