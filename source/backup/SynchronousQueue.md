### SynchronousQueue
SynchronousQueue 继承了BlockingQueue。

SynchronousQueue内部存在一个核心对象`Transferer`.Transferer 根据是否是公平还是非公平，选择使用Queue还是Stack。

Transfer 集合中又一个QNode集合，内含头指针和尾指针。如果是PUT 则是QNode的模式为Data(1)，如果是take则是REQUEST(0)

### TransferStack
遵循FILO原则

下面是一个死循环：

- 如果是REQUEST模式，切超时时间为0，直接返回。，如果发现当前的头部节点超时还会推出当前的节点。
- 如果是头部节点有超时时间，则把当前的节点添加到头部，调用`awaitFulfill `阻塞等待 `match`节点加入。
-  同理如果是DATA模式，切当前的头部节点也是`DATA`模式，说明等待往里面写入数据，也加入到阻塞头部中，通过``awaitFulfill ` LockSupport等待阻塞  `match`节点加入。

阻塞返回后，则把Request/Data的QNode 替代掉当前head，返回匹配好的数据。

- isFulfilling 校验当前是否是`11`，也就是先take 后 put的状态()[也就是先设置了DATA(`1`|`10`->`11`),再设置REQUEST].不是则是先put后take，

- isFulfilling为false，则先校验那些节点取消了，取消了则推出头节点。
- 先增加的一个节点（`Request(00)|2`->`00`,`DATA(01)|2`->`11`）节点，然后在循环中不断的便利下一个，为null了就直接返回，否则就不断的使用`tryMatch`匹配，没有匹配的节点，且通过CAS从null设置为当前节点作为匹配。

- 剩下的情况先take 后 put的状态，之前已经匹配好了，所以可以说明可以继续匹配了，可以直接获取下一个对象。

其实整个过程保证的是一个`Request`对应一个`Data` ,其余操作全部阻塞。

就是一个一对一的生产者，消费者模式。





### TransferQueue
该模式下遵循FIFO模式。