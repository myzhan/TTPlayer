#pragma once
#include <QCoreApplication>
#include <QLocalServer>
#include <QLocalSocket>
#include <QLockFile>
#include <QStandardPaths>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QCryptographicHash>
#include <functional>
#include <memory>

class InstanceGuard final : public QObject {
    QString name;
    std::unique_ptr<QLockFile> lock;
    QLocalServer server;
public:
    std::function<void(const QStringList &)> received;
    InstanceGuard() {
        const QByteArray identity=QStandardPaths::writableLocation(QStandardPaths::AppDataLocation).toUtf8();
        name=QStringLiteral("ttplayer-")+QString::fromLatin1(QCryptographicHash::hash(identity,QCryptographicHash::Sha256).toHex().left(20));
        lock=std::make_unique<QLockFile>(QDir::tempPath()+QLatin1Char('/')+name+QStringLiteral(".lock"));
    }
    bool becomePrimary(const QStringList &files) {
        if(!lock->tryLock(0)) {
            QLocalSocket socket;socket.connectToServer(name);
            if(socket.waitForConnected(2000)) {
                socket.write(QJsonDocument(QJsonArray::fromStringList(files)).toJson(QJsonDocument::Compact)+'\n');
                socket.waitForBytesWritten(1000);
            }
            return false;
        }
        QLocalServer::removeServer(name);
        if(!server.listen(name))return true;
        connect(&server,&QLocalServer::newConnection,this,[this]{
            while(auto *socket=server.nextPendingConnection()) {
                connect(socket,&QLocalSocket::readyRead,this,[this,socket]{
                    if(!socket->canReadLine())return;
                    const auto array=QJsonDocument::fromJson(socket->readLine()).array();QStringList files;
                    for(const auto &value:array)if(value.isString())files<<value.toString();
                    if(received)received(files);socket->disconnectFromServer();
                });
                connect(socket,&QLocalSocket::disconnected,socket,&QObject::deleteLater);
            }
        });return true;
    }
};
